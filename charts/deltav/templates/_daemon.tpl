{{/*
deltav.daemon — renders one daemon (Deployment + Service + optional
ServiceMonitor + optional imports PVC) from a daemon values entry.

Call with: (dict "root" $ "name" $name "daemon" $cfg)

The 12 Spring Boot daemons plus the flow/alarms sidecars are all the same
container shape; everything that differs lives in the values entry. JAVA_OPTS
and every extraEnv value are run through `tpl`, so host-bearing references like
{{ include "deltav.kafkaBootstrap" . }} resolve to the single source of truth.
*/}}
{{- define "deltav.daemon" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $d := .daemon -}}
{{- $fullname := printf "%s-%s" $root.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- $repo := $d.image | default $name -}}
{{- $usesDb := ne $d.usesDatabase false -}}
{{- $usesKafka := ne $d.usesKafka false -}}
{{- $port := int ($d.port | default 8080) -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $fullname }}
  labels:
    {{- include "deltav.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  replicas: {{ $d.replicas | default 1 }}
  selector:
    matchLabels:
      {{- include "deltav.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $name }}
  template:
    metadata:
      labels:
        {{- include "deltav.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ $name }}
    spec:
      {{- with $d.hostAliases }}
      hostAliases:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.global.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if and $d.seed $d.seed.enabled }}
      initContainers:
        - name: imports-seed
          image: {{ include "deltav.image" (dict "root" $root "repo" ($d.seed.image | default "provisiond-imports-init")) }}
          imagePullPolicy: {{ $root.Values.global.image.pullPolicy }}
          securityContext:
            runAsUser: 0
          # Signature-compare re-seed (ported from compose provisiond-imports-init):
          # copy the baked /seed into the PVC only when its content hash differs,
          # then normalise ownership/permissions for the runtime user.
          command: ["sh", "-c"]
          args:
            - |
              set -e
              NEW_SIG=$(cd /seed && find . -type f | sort | xargs md5sum 2>/dev/null | md5sum | awk '{print $1}')
              OLD_SIG=$(cat /runtime/.seed-sig 2>/dev/null || echo none)
              if [ "$NEW_SIG" != "$OLD_SIG" ]; then
                  echo "[imports-seed] seeding /runtime ($OLD_SIG -> $NEW_SIG)"
                  cp -R /seed/. /runtime/
                  printf '%s\n' "$NEW_SIG" > /runtime/.seed-sig
              else
                  echo "[imports-seed] /runtime current ($NEW_SIG) — normalising perms"
              fi
              chown -R 100:101 /runtime
              chmod 755 /runtime
              find /runtime -type d -exec chmod 755 {} +
              find /runtime -type f -exec chmod 644 {} +
          volumeMounts:
            - name: imports
              mountPath: /runtime
      {{- end }}
      containers:
        - name: {{ $name }}
          image: {{ include "deltav.image" (dict "root" $root "repo" $repo) }}
          imagePullPolicy: {{ $root.Values.global.image.pullPolicy }}
          {{- with $d.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ $port }}
              protocol: TCP
            {{- with $d.extraPorts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          env:
            - name: OPENNMS_HOME
              value: {{ $d.opennmsHome | default "/opt/deltav" | quote }}
            - name: OPENNMS_INSTANCE_ID
              value: {{ $root.Values.global.instanceId | quote }}
            {{- if $d.tsidNodeId }}
            - name: OPENNMS_TSID_NODE_ID
              value: {{ $d.tsidNodeId | quote }}
            {{- end }}
            {{- if $d.javaOpts }}
            - name: JAVA_OPTS
              value: {{ tpl $d.javaOpts $root | quote }}
            {{- end }}
            {{- if $usesKafka }}
            - name: {{ $d.kafkaEnvVar | default "KAFKA_BOOTSTRAP_SERVERS" }}
              value: {{ include "deltav.kafkaBootstrap" $root | quote }}
            {{- end }}
            {{- if $d.consumerGroup }}
            - name: KAFKA_CONSUMER_GROUP
              value: {{ $d.consumerGroup | quote }}
            {{- end }}
            {{- if $d.sinkConsumerGroup }}
            - name: KAFKA_SINK_CONSUMER_GROUP
              value: {{ $d.sinkConsumerGroup | quote }}
            {{- end }}
            {{- if $usesDb }}
            - name: SPRING_DATASOURCE_URL
              value: {{ include "deltav.jdbcUrl" $root | quote }}
            - name: SPRING_DATASOURCE_USERNAME
              value: {{ $root.Values.global.postgres.username | default "opennms" | quote }}
            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "deltav.dbSecretName" $root }}
                  key: {{ $root.Values.global.postgres.passwordKey | default "password" }}
            {{- end }}
            {{- range $k, $v := $d.extraEnv }}
            - name: {{ $k }}
              value: {{ tpl (toString $v) $root | quote }}
            {{- end }}
          readinessProbe:
            httpGet:
              path: {{ $d.probePath | default "/actuator/health" }}
              port: http
            initialDelaySeconds: {{ $d.probeInitialDelay | default 20 }}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: {{ $d.probePath | default "/actuator/health" }}
              port: http
            initialDelaySeconds: {{ add ($d.probeInitialDelay | default 20) 60 }}
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 6
          {{- with $d.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if and $d.seed $d.seed.enabled }}
          volumeMounts:
            - name: imports
              mountPath: {{ $d.seed.mountPath | default "/opt/deltav/etc/imports" }}
          {{- end }}
      {{- if $d.stopGracePeriodSeconds }}
      terminationGracePeriodSeconds: {{ $d.stopGracePeriodSeconds }}
      {{- end }}
      {{- if and $d.seed $d.seed.enabled }}
      volumes:
        - name: imports
          persistentVolumeClaim:
            claimName: {{ $fullname }}-imports
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}
  labels:
    {{- include "deltav.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  type: ClusterIP
  selector:
    {{- include "deltav.selectorLabels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
  ports:
    - name: http
      port: {{ $port }}
      targetPort: http
      protocol: TCP
{{- if and $d.seed $d.seed.enabled }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $fullname }}-imports
  labels:
    {{- include "deltav.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  accessModes:
    - {{ $d.seed.accessMode | default "ReadWriteOnce" }}
  resources:
    requests:
      storage: {{ $d.seed.size | default "1Gi" }}
  {{- with $d.seed.storageClass }}
  storageClassName: {{ . }}
  {{- end }}
{{- end }}
{{- $smGlobal := $root.Values.metrics.serviceMonitor -}}
{{- if and $smGlobal.enabled (ne (default true $d.serviceMonitor) false) }}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ $fullname }}
  labels:
    {{- include "deltav.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
    {{- with $smGlobal.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "deltav.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $name }}
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: {{ $smGlobal.interval | default "15s" }}
{{- end }}
{{- end -}}
