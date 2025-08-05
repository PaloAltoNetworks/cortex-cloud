{{- define "common.validateImage" -}}
  {{- if or (not .Values.image.name) (eq .Values.image.name "") -}}
    {{- fail (print "Error: 'image.name' is missing or empty. Provided value: '" .Values.image.name "'") -}}
  {{- end -}}

  {{- if or (not .Values.image.repository) (eq .Values.image.repository "") -}}
    {{- fail (print "Error: 'image.repository' is missing or empty. Provided value: '" .Values.image.repository "'") -}}
  {{- end -}}

  {{- if and (not .Values.image.tag) (not .Values.image.digest) -}}
    {{- fail "Error: Either 'image.tag' or 'image.digest' must be provided for the image." -}}
  {{- end -}}

  {{- if and (eq (.Values.image.tag | toString) "") (eq (.Values.image.digest | toString) "") -}}
    {{- fail (print "Error: Both 'image.tag' and 'image.digest' cannot be empty.") -}}
  {{- end -}}

{{- end -}}


{{- define "common.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/author: {{ .Values.namespace.name }}
{{- end -}}

{{- define "common.jobTemplate" -}}
spec:
  backoffLimit: {{ .Values.system.batch.backoffLimit }}
  template:
    metadata:
      labels:
        {{- include "common.labels" . | nindent 8 }}
        app.kubernetes.io/component: {{ .Release.Name }}
    spec:
      {{- with .Values.system.apps.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.system.apps.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumes:
        - name: {{ .Values.system.secrets.backendAuth.name }}
          secret:
            secretName: {{ .Values.system.secrets.backendAuth.name }}
      serviceAccountName: {{ .Values.system.serviceAccount.name }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}/{{ .Values.image.name }}{{- if .Values.image.tag }}:{{ .Values.image.tag }}{{- end }}{{- if .Values.image.digest }}@{{ .Values.image.digest }}{{- end }}"
          command: [/{{ .Chart.Name }}]
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: DISTRIBUTION_ID
              valueFrom:
                secretKeyRef:
                  name: distribution-id
                  key: distribution-id
          envFrom:
            - configMapRef:
                name: {{ .Values.system.configMap.global.name }}
          volumeMounts:
            - mountPath: "/secret"
              name: {{ .Values.system.secrets.backendAuth.name }}
              readOnly: true
      restartPolicy: Never
{{- end -}}

{{- define "common.apiGroupsWithoutVersions" }}
{{- $groups := dict }}
{{- range .Capabilities.APIVersions }}
  {{- $parts := splitList "/" . }}
  {{- $key := "" }}
  {{- if gt (len $parts) 1 }}
    {{- $key = index $parts 0 }}
  {{- end }}
  {{- $_ := set $groups $key true }}
{{- end }}
{{ $groups | toYaml }}
{{- end }}
