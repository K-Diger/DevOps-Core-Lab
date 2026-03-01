{{/*
공통 라벨 - Gatekeeper 필수 라벨(app, env, team)을 강제 포함
*/}}
{{- define "demo-app.labels" -}}
app: {{ .component }}
env: {{ .global.env }}
team: {{ .global.team }}
{{- end }}

{{/*
Selector 라벨 - matchLabels용
*/}}
{{- define "demo-app.selectorLabels" -}}
app: {{ .component }}
{{- end }}

{{/*
Pod Security Context - runAsNonRoot 보장
*/}}
{{- define "demo-app.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
{{- end }}
