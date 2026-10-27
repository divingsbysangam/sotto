#!/bin/bash
# Build a service-free SwiftUI prototype without starting the Sotto application.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"
mkdir -p .context/redesign-preview
xcrun swiftc -D DEBUG -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    Sotto/Views/Components/NativeDesign.swift \
    Sotto/Models/PanelPresentation.swift \
    Sotto/Views/NotchCapsuleWindow.swift \
    Sotto/Views/FloatingDictationView.swift \
    Sotto/Views/CursorIndicatorWindow.swift \
    Sotto/Views/Redesign/RedesignFixtures.swift \
    Sotto/Views/Redesign/RedesignPrototype.swift \
    Sotto/Views/Redesign/SupportingWindowPrototypes.swift \
    scripts/RedesignPreview.swift \
    -o .context/redesign-preview/SottoDesignPreview
exec .context/redesign-preview/SottoDesignPreview "$@"
