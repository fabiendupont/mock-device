{{/*
Expand the name of the chart.
*/}}
{{- define "mock-device.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mock-device.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mock-device.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mock-device.labels" -}}
helm.sh/chart: {{ include "mock-device.chart" . }}
{{ include "mock-device.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mock-device.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mock-device.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Controller labels
*/}}
{{- define "mock-device.controller.labels" -}}
{{ include "mock-device.labels" . }}
app.kubernetes.io/component: controller
app: mock-accel-controller
{{- end }}

{{/*
Node agent labels
*/}}
{{- define "mock-device.nodeAgent.labels" -}}
{{ include "mock-device.labels" . }}
app.kubernetes.io/component: node-agent
app: mock-accel-node-agent
{{- end }}

{{/*
Create the name of the controller service account to use
*/}}
{{- define "mock-device.controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "mock-accel-controller" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the node agent service account to use
*/}}
{{- define "mock-device.nodeAgent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "mock-accel-node-agent" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
DRA driver image
*/}}
{{- define "mock-device.draDriver.image" -}}
{{- $tag := .Values.draDriver.controller.image.tag | default .Chart.AppVersion }}
{{- printf "%s:v%s" .Values.draDriver.controller.image.repository $tag }}
{{- end }}

{{/*
Kernel module image
*/}}
{{- define "mock-device.kernelModule.image" -}}
{{- printf "%s:%s" .Values.kernelModule.image.repository .Values.kernelModule.image.tag }}
{{- end }}

{{/*
Namespace name
*/}}
{{- define "mock-device.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}
