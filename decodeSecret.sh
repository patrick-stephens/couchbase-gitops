#!/bin/bash
set -eux
SECRET_NAME=${SECRET_NAME:-$1}

kubectl get secret "${SECRET_NAME}" -o go-template='{{range $k,$v := .data}}{{printf "%s: " $k}}{{if not $v}}{{$v}}{{else}}{{$v | base64decode}}{{end}}{{"\n"}}{{end}}'