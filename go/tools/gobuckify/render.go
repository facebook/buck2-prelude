/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is dual-licensed under either the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree or the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree. You may select, at your option, one of the
 * above-listed licenses.
 */

package main

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"text/template"
)

var targetTempate = `
{{- .Config.Preambule }}
{{- if .Target.IsBinary }}
{{- .Config.LoadGoBinaryRule}}
{{- else }}
{{- .Config.LoadGoLibraryRule}}
{{- end }}
{{- if .Target.IsBinary }}{{ .Config.GoBinaryRule}}{{ else }}{{ .Config.GoLibraryRule}}{{ end }}(
    name = "{{.Target.Name}}",
    package_name = "{{.Target.ImportPath}}",
    srcs = native.glob(["*.go", "*.s", "*.h", "*.c", "*.cc", "*.cpp", "*.S"]),
    header_namespace = "",
    {{- if or .Target.CommonDeps .Target.PlatformDeps }}
    {{.Config.DepsAttr}} = [
        {{- range .Target.CommonDeps }}
        {{- if $.Config.DepsTargetLabelPrefix }}
        "{{targetLabelFromImportPath $.Config.DepsTargetLabelPrefix .}}",
        {{- else }}
        "{{.}}",
        {{- end }}
        {{- end }}
    ]{{ if .Target.PlatformDeps }} + select({
        "DEFAULT": [],
        {{- range $os, $osDeps := .Target.PlatformDeps }}
        "{{ $os }}": select({
            "DEFAULT": [],
            {{- range $arch, $archDeps := $osDeps.ArchDeps }}
            "{{ $arch }}": [
                {{- range $archDeps.Deps.SortedList }}
                {{- if $.Config.DepsTargetLabelPrefix }}
                "{{targetLabelFromImportPath $.Config.DepsTargetLabelPrefix .}}",
                {{- else }}
                "{{.}}",
                {{- end }}
                {{- end }}
            ],
            {{- end }}
        }),
        {{- end }}
    }){{ end }},
    {{- end }}
    {{- if and .Target.EmbedFiles .Config.GenerateEmbedSrcs }}
    embed_srcs = [
        {{- range .Target.EmbedFiles }}
        "{{.}}",
        {{- end }}
    ],
    {{- end }}
    {{- if .Target.TargetCompatibleWith }}
    target_compatible_with = select({
        "DEFAULT": ["config//:none"],
        {{- range $os, $archList := .Target.TargetCompatibleWith }}
        "{{ $os }}": select({
            "DEFAULT": ["config//:none"],
            {{- range $archList }}
            "{{.}}": [],
            {{- end }}
        }),
        {{- end }}
    }),
    {{- end }}
    visibility = ["PUBLIC"],
)
`

type templateData struct {
	Config BuckConfig
	Target *BuckTarget
}

func renderBuckFiles(cfg *Config, thirdPartyDir string, buckTargets BuckTargets) error {
	tmpl1 := template.New("buck")
	tmpl1.Funcs(template.FuncMap{
		"targetLabelFromImportPath": targetLabelFromImportPath,
	})
	tmpl1 = template.Must(tmpl1.Parse(targetTempate))

	for _, target := range buckTargets {
		buckFile := filepath.Join(thirdPartyDir, "vendor", target.ImportPath, "BUCK")
		f, err := os.Create(buckFile)
		if err != nil {
			return fmt.Errorf("can't create BUCK file: %w", err)
		}
		defer f.Close()

		if err := tmpl1.Execute(f, templateData{Config: cfg.Buck, Target: target}); err != nil {
			slog.Error("Error executing template:", "err", err)
		}
	}
	return nil
}
