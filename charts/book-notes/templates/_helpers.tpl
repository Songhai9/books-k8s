{{- define "book-notes.commonLabels" -}}
app.kubernetes.io/part-of: book-notes
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "book-notes.appSelectorLabels" -}}
app.kubernetes.io/name: book-notes
app.kubernetes.io/part-of: book-notes
{{- end }}

{{- define "book-notes.postgresSelectorLabels" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/part-of: book-notes
{{- end }}
