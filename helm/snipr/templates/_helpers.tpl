{{- define "snipr.labels" -}}
app.kubernetes.io/part-of: snipr
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "snipr.secretEnv" -}}
{{- range list "POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB" }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ $.Values.existingSecret }}
      key: {{ . }}
{{- end }}
{{- end -}}

{{- define "snipr.restricted" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
