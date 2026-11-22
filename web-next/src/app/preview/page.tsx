import { Suspense } from "react"
import type { Viewport } from "next"

import { FilePreviewPage } from "@/components/file-preview-page"

// The preview route is the one page the iOS app renders inside its own
// WebView. Without `viewport-fit=cover` the layout viewport stops at the home
// indicator and the uncovered strip shows the WebView's own background — a
// white band under dark content (pp 2026-11-22). Scoping the viewport to this
// route keeps the rest of the Web app's layout untouched.
export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  viewportFit: "cover",
  colorScheme: "dark light"
}

export default function PreviewPage() {
  return (
    <Suspense fallback={null}>
      <FilePreviewPage />
    </Suspense>
  )
}
