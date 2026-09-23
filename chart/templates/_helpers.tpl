{{- define "fyers-collector.name" -}}
app.kubernetes.io/name: fyers-collector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "fyers-collector.fullname" -}}
{{ .Release.Name }}
{{- end -}}

{{- /* The data PVC: reuse an existing claim when named, else create one. */ -}}
{{- define "fyers-collector.dataClaim" -}}
{{- if .Values.storage.existingClaim -}}
{{ .Values.storage.existingClaim }}
{{- else -}}
{{ include "fyers-collector.fullname" . }}-data
{{- end -}}
{{- end -}}
