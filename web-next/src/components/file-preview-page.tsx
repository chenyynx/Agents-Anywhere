"use client"

import * as React from "react"
import { toast } from "sonner"
import { copyText as copyToClipboard } from "@/lib/clipboard"
import {
  Check,
  ChevronRight,
  Copy,
  Download,
  Edit3,
  ExternalLink,
  File,
  FileWarning,
  Folder,
  FolderOpen,
  Loader2,
  RotateCw,
  Save,
  Search,
  X,
} from "lucide-react"
import { useTranslations } from "next-intl"

import { useRouteSearchParams } from "@/components/hash-route-params"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Spinner } from "@/components/ui/spinner"
import { Switch } from "@/components/ui/switch"
import { MonacoCodeView, type MonacoCodeViewApi } from "@/components/monaco-code-view"
import { EmbeddedPreviewHeader } from "@/components/embedded-preview-header"
import { filePreviewLocation, type FilePreviewLocation } from "@/lib/file-preview-location"
import { openNativeFilePreviewWindow } from "@/lib/file-preview-window"
import { dashboardApi } from "@/features/dashboard/api"
import { loadStoredSession } from "@/features/auth/session"
import type { FsEntry, FsPreviewSessionResponse, FsReadTextResult } from "@/features/dashboard/types"
import { cn } from "@/lib/utils"
import { filePathBreadcrumbSegments } from "@/lib/file-path-breadcrumb"

type PreviewState =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "directory"; path: string; entries: FsEntry[] }
  | { kind: "text"; file: FsReadTextResult }
  | { kind: "binary"; file: BinaryFileInfo; objectUrl: string | null }

type BinaryFileInfo = {
  path: string
  name: string
  size: number
  sha256: string
  mediaType: string
  downloadUrl: string
}

const TEXT_MAX_BYTES = 1_000_000

export function FilePreviewPage() {
  const params = useRouteSearchParams()
  // The whole page is driven by the URL fragment (preview token, embedded
  // flag), which the server cannot see. Mounting client-side keeps the server
  // and first client render identical instead of hydrating the browser header
  // and then swapping in the app skin (pp 2026-11-22).
  const [mounted, setMounted] = React.useState(false)
  React.useEffect(() => { setMounted(true) }, [])
  const connectorId = params.get("connectorId") ?? ""
  const root = params.get("root") ?? ""
  const routePath = params.get("path") ?? ""
  const previewToken = params.get("previewToken") ?? ""
  const routeName = params.get("name") ?? ""
  const sourceUrl = params.get("sourceUrl") ?? ""
  const sourceMediaType = params.get("mediaType") ?? ""
  const sourceSize = routeSourceSize(params.get("size"))
  const token = React.useMemo(() => loadStoredSession()?.accessToken ?? null, [])

  if (!mounted) return null

  return (
    <FilePreviewSurface
      key={`${connectorId}:${root}:${routePath}:${previewToken}:${sourceUrl}`}
      token={token}
      connectorId={connectorId}
      root={root}
      initialPath={routePath}
      initialName={routeName}
      initialLocation={filePreviewLocation(params.get("line"), params.get("column"))}
      previewToken={previewToken}
      sourceUrl={sourceUrl}
      sourceMediaType={sourceMediaType}
      sourceSize={sourceSize}
      readOnly={Boolean(sourceUrl)}
      mode="window"
      // The app marks its own WebView with embedded=1; the system browser
      // keeps the full Web page (pp 2026-11-22).
      embeddedSkin={params.get("embedded") === "1"}
    />
  )
}

function routeSourceSize(value: string | null): number | undefined {
  if (value === null || value === "") return undefined
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined
}

type FilePreviewSurfaceProps = {
  token: string | null
  connectorId: string
  root: string
  initialPath: string
  initialName?: string
  initialLocation?: FilePreviewLocation
  previewToken?: string
  sourceUrl?: string
  sourceMediaType?: string
  sourceSize?: number
  readOnly?: boolean
  mode?: "window" | "embedded"
  /** The app's WebView skin: floating cards, paper read mode, dark edit mode. */
  embeddedSkin?: boolean
  onDirtyChange?: (dirty: boolean) => void
  onOpenExternal?: () => void
}

export function FilePathBreadcrumb({ path, renderSegment }: {
  path: string
  renderSegment?: (segment: { label: string; path: string }, current: boolean) => React.ReactNode
}) {
  const viewportRef = React.useRef<HTMLDivElement | null>(null)
  const contentRef = React.useRef<HTMLDivElement | null>(null)
  const normalizedPath = path.trim().replaceAll("\\", "/") || "."
  const segments = React.useMemo(() => filePathBreadcrumbSegments(normalizedPath), [normalizedPath])

  React.useLayoutEffect(() => {
    const viewport = viewportRef.current
    const content = contentRef.current
    if (!viewport || !content) return

    const measure = () => { viewport.scrollLeft = viewport.scrollWidth }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(viewport)
    observer.observe(content)
    return () => observer.disconnect()
  }, [segments])

  return (
    <div
      ref={viewportRef}
      className="aa-file-preview-breadcrumb-viewport min-w-0 flex-1"
      dir="ltr"
      title={normalizedPath}
      aria-label={normalizedPath}
    >
      <div ref={contentRef} className="aa-file-preview-breadcrumb">
        {segments.map((segment, index) => (
          <React.Fragment key={segment.path}>
            {index > 0 ? <ChevronRight aria-hidden="true" className="aa-file-preview-breadcrumb-separator" /> : null}
            {renderSegment ? renderSegment(segment, index === segments.length - 1) : (
              <span
                className={cn("aa-file-preview-breadcrumb-segment", index === segments.length - 1 && "current")}
                aria-current={index === segments.length - 1 ? "location" : undefined}
              >
                {segment.label}
              </span>
            )}
          </React.Fragment>
        ))}
      </div>
    </div>
  )
}

export function FilePreviewSurface({
  token,
  connectorId,
  root,
  initialPath,
  initialName = "",
  initialLocation,
  previewToken = "",
  sourceUrl = "",
  sourceMediaType = "",
  sourceSize,
  readOnly = false,
  mode = "embedded",
  embeddedSkin = false,
  onOpenExternal,
  onDirtyChange,
}: FilePreviewSurfaceProps) {
  const t = useTranslations("preview")
  const tCommon = useTranslations("common")
  const tokenRef = React.useRef(token)
  tokenRef.current = token
  const translationRef = React.useRef(t)
  translationRef.current = t
  const routePath = initialPath
  const [previewSession, setPreviewSession] = React.useState<FsPreviewSessionResponse | null>(null)
  const [navigation, setNavigation] = React.useState({ origin: routePath, path: routePath })
  const path = navigation.origin === routePath ? navigation.path : routePath
  const setPath = (nextPath: string) => setNavigation({ origin: routePath, path: nextPath })
  const effectivePath = previewSession?.path ?? path
  const name = path === routePath ? initialName || fileNameFromPath(effectivePath) : fileNameFromPath(effectivePath)
  const [state, setState] = React.useState<PreviewState>({ kind: "loading" })
  const [loadingFile, setLoadingFile] = React.useState(true)
  const [loadedPath, setLoadedPath] = React.useState<string | null>(null)
  const pendingFile = loadingFile || loadedPath !== path
  const [editMode, setEditMode] = React.useState(false)
  const [dirty, setDirty] = React.useState(false)
  const [saving, setSaving] = React.useState(false)
  const [saveError, setSaveError] = React.useState<string | null>(null)
  const [downloadError, setDownloadError] = React.useState<string | null>(null)
  const [savedFlash, setSavedFlash] = React.useState(false)
  const [copied, setCopied] = React.useState(false)
  const embeddedEditModeId = React.useId()
  const editorRef = React.useRef<MonacoCodeViewApi | null>(null)
  const editorInitialContentRef = React.useRef("")
  const objectUrlRef = React.useRef<string | null>(null)
  const loadRequestIdRef = React.useRef(0)
  const containerRef = React.useRef<HTMLElement | null>(null)
  const contentRef = React.useRef<HTMLElement | null>(null)
  const [zoom, setZoom] = React.useState(1)
  const [viewMode, setViewMode] = React.useState<"zoom" | "fixed">("zoom")
  const [zoomPill, setZoomPill] = React.useState(false)
  const zoomRef = React.useRef(1)
  zoomRef.current = zoom
  const zoomPillTimer = React.useRef<number | null>(null)

  React.useEffect(() => { onDirtyChange?.(dirty) }, [dirty, onDirtyChange])

  const isScopedPreview = Boolean(previewToken)
  const isSourcePreview = Boolean(sourceUrl)
  const readOnlyPreview = readOnly || isScopedPreview || isSourcePreview
  const canLoad = isScopedPreview || isSourcePreview || Boolean(token && connectorId && root && path)
  const zoomableKind = state.kind === "binary" ? previewKind(state.file.mediaType, state.file.name) : null
  const canZoom = embeddedSkin && (state.kind === "text" || zoomableKind === "image" || zoomableKind === "pdf")
  const toolKind: "code" | "image" | "pdf" | "other" =
    state.kind === "text" ? "code" : zoomableKind === "image" ? "image" : zoomableKind === "pdf" ? "pdf" : "other"
  const fixedView = viewMode === "fixed" && (toolKind === "image" || toolKind === "pdf")

  const revokeObjectUrl = React.useCallback(() => {
    if (objectUrlRef.current) URL.revokeObjectURL(objectUrlRef.current)
    objectUrlRef.current = null
  }, [])

  const loadFile = React.useCallback(async () => {
    const token = tokenRef.current
    const t = translationRef.current
    const requestId = ++loadRequestIdRef.current
    const requestIsCurrent = () => requestId === loadRequestIdRef.current
    setZoom(1)
    setViewMode("zoom")
    setZoomPill(false)
    revokeObjectUrl()
    setLoadingFile(true)
    setState((previous) => previous.kind === "text" ? previous : { kind: "loading" })
    setDirty(false)
    setEditMode(false)
    setSaveError(null)
    setDownloadError(null)
    setSavedFlash(false)
    if (!canLoad) {
      setState({ kind: "error", message: t("missingContext") })
      setLoadedPath(path)
      setLoadingFile(false)
      return
    }
    try {
      if (sourceUrl) {
        const blob = await dashboardApi.downloadBlob(token, sourceUrl)
        if (!requestIsCurrent()) return
        const mediaType = resolvedPreviewMediaType(sourceMediaType, blob.type, name)
        const size = sourceSize ?? blob.size
        if (canTextPreview(mediaType, name)) {
          const truncated = blob.size > TEXT_MAX_BYTES
          const content = await blob.slice(0, TEXT_MAX_BYTES).text()
          if (!requestIsCurrent()) return
          setState({
            kind: "text",
            file: {
              path,
              name,
              size,
              sha256: `source:${blob.size}:${mediaType}`,
              encoding: "utf-8",
              content,
              truncated,
              binary: false,
              serverTime: new Date().toISOString(),
            },
          })
          return
        }
        const binary: BinaryFileInfo = {
          path,
          name,
          size,
          sha256: `source:${blob.size}:${mediaType}`,
          mediaType,
          downloadUrl: sourceUrl,
        }
        let objectUrl: string | null = null
        if (canBrowserPreview(mediaType, name)) {
          objectUrl = URL.createObjectURL(new Blob([blob], {
            type: mediaType || blob.type || "application/octet-stream",
          }))
          if (!requestIsCurrent()) {
            URL.revokeObjectURL(objectUrl)
            return
          }
          objectUrlRef.current = objectUrl
        }
        if (!requestIsCurrent()) return
        setState({ kind: "binary", file: binary, objectUrl })
        return
      }
      let scopedSession = previewSession
      if (previewToken && !scopedSession) {
        scopedSession = await dashboardApi.createConnectorFsPreviewSession(previewToken)
        if (!requestIsCurrent()) return
        setPreviewSession(scopedSession)
      }
      const text = scopedSession
        ? await dashboardApi.connectorFsPreviewReadText(scopedSession.previewAccessToken, TEXT_MAX_BYTES)
        : token
          ? await dashboardApi.connectorFsReadText(token, connectorId, root, path, TEXT_MAX_BYTES)
          : null
      if (!requestIsCurrent()) return
      if (!text) {
        setState({ kind: "error", message: t("missingContext") })
        return
      }
      if (!text.binary) {
        setState({ kind: "text", file: text })
        return
      }
      const response = scopedSession
        ? await dashboardApi.connectorFsPreviewRead(scopedSession.previewAccessToken)
        : token
          ? await dashboardApi.connectorFsRead(token, connectorId, root, path)
          : null
      if (!requestIsCurrent()) return
      if (!response) {
        setState({ kind: "error", message: t("missingContext") })
        return
      }
      const mediaType = response.result.mediaType || mediaTypeForFile(response.result.name || name)
      const binary: BinaryFileInfo = {
        ...response.result,
        mediaType,
      }
      let objectUrl: string | null = null
      if (canBrowserPreview(mediaType, binary.name)) {
        const blob = await dashboardApi.downloadBlob(scopedSession ? null : token, binary.downloadUrl)
        if (!requestIsCurrent()) return
        objectUrl = URL.createObjectURL(new Blob([blob], { type: mediaType || blob.type || "application/octet-stream" }))
        if (!requestIsCurrent()) {
          URL.revokeObjectURL(objectUrl)
          return
        }
        objectUrlRef.current = objectUrl
      }
      if (!requestIsCurrent()) return
      setState({ kind: "binary", file: binary, objectUrl })
    } catch (err) {
      if (!requestIsCurrent()) return
      if (!sourceUrl && !previewToken && token && connectorId && path) {
        try {
          const response = await dashboardApi.connectorFsList(token, connectorId, { root, path })
          if (!requestIsCurrent()) return
          if (samePath(response.result.path, path)) {
            setState({ kind: "directory", path: response.result.path, entries: response.result.entries })
            return
          }
        } catch {
          // Preserve the original file-preview error when the target is not a directory.
        }
      }
      if (!requestIsCurrent()) return
      setState({ kind: "error", message: err instanceof Error ? err.message : String(err) })
    } finally {
      if (requestIsCurrent()) {
        setLoadedPath(path)
        setLoadingFile(false)
      }
    }
  }, [
    canLoad,
    connectorId,
    name,
    path,
    previewSession,
    previewToken,
    revokeObjectUrl,
    root,
    sourceMediaType,
    sourceSize,
    sourceUrl,
  ])

  React.useEffect(() => {
    void loadFile()
    return () => {
      loadRequestIdRef.current += 1
      revokeObjectUrl()
    }
  }, [loadFile, revokeObjectUrl])

  const showZoomPill = React.useCallback(() => {
    setZoomPill(true)
    if (zoomPillTimer.current !== null) window.clearTimeout(zoomPillTimer.current)
    zoomPillTimer.current = window.setTimeout(() => setZoomPill(false), 1500)
  }, [])

  React.useEffect(() => () => {
    if (zoomPillTimer.current !== null) window.clearTimeout(zoomPillTimer.current)
  }, [])

  // Content-level pinch: the toolbar never moves; text scales through the
  // Monaco font size, images and PDFs scale their own content (pp 2026-11-22).
  React.useEffect(() => {
    const node = contentRef.current
    if (!node || !canZoom || fixedView) return
    let startDistance = 0
    let startZoom = 1
    let pinching = false
    const distance = (touches: TouchList) => {
      const a = touches[0]
      const b = touches[1]
      return a && b ? Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY) : 0
    }
    const onStart = (event: TouchEvent) => {
      if (event.touches.length !== 2) { pinching = false; return }
      startDistance = distance(event.touches)
      startZoom = zoomRef.current
      pinching = true
    }
    const onMove = (event: TouchEvent) => {
      if (!pinching || event.touches.length !== 2 || startDistance <= 0) return
      event.preventDefault()
      setZoom(Math.min(3, Math.max(0.5, startZoom * distance(event.touches) / startDistance)))
      showZoomPill()
    }
    const onEnd = (event: TouchEvent) => {
      if (event.touches.length < 2) pinching = false
    }
    // iOS WebKit reports a two-finger pinch as gesture* events (and may keep
    // the touchmove to itself). Handle both; capture phase so Monaco cannot
    // swallow the gesture before it reaches the page (pp 2026-11-22).
    let gestureStartZoom = 1
    const onGestureStart = (event: Event) => {
      event.preventDefault()
      gestureStartZoom = zoomRef.current
    }
    const onGestureChange = (event: Event) => {
      event.preventDefault()
      const scale = Number((event as Event & { scale?: number }).scale)
      if (!Number.isFinite(scale) || scale <= 0) return
      setZoom(Math.min(3, Math.max(0.5, gestureStartZoom * scale)))
      showZoomPill()
    }
    const onGestureEnd = (event: Event) => { event.preventDefault() }
    node.addEventListener("touchstart", onStart, { capture: true, passive: true })
    node.addEventListener("touchmove", onMove, { capture: true, passive: false })
    node.addEventListener("touchend", onEnd, { capture: true, passive: true })
    node.addEventListener("touchcancel", onEnd, { capture: true, passive: true })
    node.addEventListener("gesturestart", onGestureStart, { capture: true, passive: false })
    node.addEventListener("gesturechange", onGestureChange, { capture: true, passive: false })
    node.addEventListener("gestureend", onGestureEnd, { capture: true, passive: false })
    return () => {
      node.removeEventListener("touchstart", onStart, { capture: true })
      node.removeEventListener("touchmove", onMove, { capture: true })
      node.removeEventListener("touchend", onEnd, { capture: true })
      node.removeEventListener("touchcancel", onEnd, { capture: true })
      node.removeEventListener("gesturestart", onGestureStart, { capture: true })
      node.removeEventListener("gesturechange", onGestureChange, { capture: true })
      node.removeEventListener("gestureend", onGestureEnd, { capture: true })
    }
  }, [canZoom, fixedView, showZoomPill])

  React.useEffect(() => {
    if (mode !== "window") return
    if (state.kind === "loading" || state.kind === "error") return
    const stateName = state.kind === "directory" ? fileNameFromPath(state.path) : state.file.name
    document.title = `${stateName || name} - ${t("title")}`
  }, [mode, name, state, t])

  React.useEffect(() => {
    if (state.kind !== "text") return
    editorInitialContentRef.current = state.file.content
  }, [state])

  const handleEditorReady = React.useCallback((api: MonacoCodeViewApi) => {
    editorRef.current = api
    if (initialLocation && path === routePath) api.revealPosition(initialLocation)
  }, [initialLocation, path, routePath])

  const handleEditorChange = React.useCallback(
    (value: string) => setDirty(value !== editorInitialContentRef.current),
    [],
  )

  const handleDownload = React.useCallback(async () => {
    if (pendingFile) return
    setDownloadError(null)
    if (!token && !readOnlyPreview) return
    try {
      if (sourceUrl) {
        const blob = await dashboardApi.downloadBlob(token, sourceUrl)
        const sourceName = state.kind === "text" || state.kind === "binary"
          ? state.file.name
          : name
        downloadBlob(blob, sourceName || name)
        return
      }
      if (state.kind === "text") {
        const content = editorRef.current?.getValue() ?? state.file.content
        downloadBlob(new Blob([content], { type: "text/plain;charset=utf-8" }), state.file.name || name)
        return
      }
      if (state.kind === "binary") {
        const blob = state.objectUrl
          ? await fetch(state.objectUrl).then((response) => response.blob())
          : await dashboardApi.downloadBlob(isScopedPreview ? null : token, state.file.downloadUrl)
        downloadBlob(blob, state.file.name || name)
      }
    } catch (err) {
      setDownloadError(err instanceof Error ? err.message : String(err))
    }
  }, [isScopedPreview, name, pendingFile, readOnlyPreview, sourceUrl, state, token])

  const handleSave = React.useCallback(async () => {
    if (pendingFile || readOnlyPreview || !token || state.kind !== "text" || !editorRef.current || !editMode) return false
    const content = editorRef.current.getValue()
    setSaving(true)
    setSaveError(null)
    try {
      const response = await dashboardApi.connectorFsWrite(token, connectorId, root, {
        path,
        content,
        ifMatch: state.file.sha256,
      })
      setState((current) =>
        current.kind === "text"
          ? {
              kind: "text",
              file: {
                ...current.file,
                content,
                sha256: response.result.sha256,
                size: response.result.bytesWritten,
                truncated: false,
              },
            }
          : current,
      )
      setDirty(false)
      setSavedFlash(true)
      window.setTimeout(() => setSavedFlash(false), 1500)
      return true
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setSaveError(message.includes("412") ? t("saveConflict") : message)
      return false
    } finally {
      setSaving(false)
    }
  }, [connectorId, editMode, path, pendingFile, readOnlyPreview, root, state, t, token])

  const handleEmbeddedEditModeChange = React.useCallback(
    (checked: boolean) => {
      if (readOnlyPreview || state.kind !== "text" || saving) return
      if (!checked && dirty) {
        setSaveError(t("saveBeforeLeavingEdit"))
        return
      }
      setSaveError(null)
      setEditMode(checked)
      if (checked) window.requestAnimationFrame(() => editorRef.current?.focus())
    },
    [dirty, readOnlyPreview, saving, state.kind, t],
  )

  React.useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (mode === "embedded" && !containerRef.current?.contains(document.activeElement)) return
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault()
        void handleSave()
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
        if (editorRef.current) {
          event.preventDefault()
          editorRef.current.openSearch()
        }
      }
    }
    window.addEventListener("keydown", onKeyDown, true)
    return () => window.removeEventListener("keydown", onKeyDown, true)
  }, [handleSave, mode])

  React.useEffect(() => {
    if (!dirty) return
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", onBeforeUnload)
    return () => window.removeEventListener("beforeunload", onBeforeUnload)
  }, [dirty])

  const copyText = React.useCallback(async () => {
    if (state.kind !== "text") return
    setCopied(false)
    try {
      await copyToClipboard(editorRef.current?.getValue() ?? state.file.content)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1200)
    } catch {
      toast.error(tCommon("copyFailed"))
    }
  }, [state, tCommon])

  return (
    <main
      ref={containerRef}
      className={cn(
        "flex h-full min-h-0 flex-col overflow-hidden bg-background text-foreground",
        embeddedSkin && "aa-preview-embedded",
        // dvh, not svh: in the app's WebView `svh` stops at the bottom safe
        // area even with viewport-fit=cover, leaving a 34 pt strip of the
        // WebView background below the page (pp 2026-11-22).
        mode === "window" && "h-dvh",
      )}
      // viewport-fit=cover lets the page paint under the home indicator; keep
      // the scrolling content above it without leaving a background gap.
      style={mode === "window" || embeddedSkin
        ? { paddingBottom: "env(safe-area-inset-bottom)" }
        : undefined}
    >
      {embeddedSkin ? (
        <EmbeddedPreviewHeader
          kind={toolKind}
          canEdit={state.kind === "text" && !readOnlyPreview}
          canCopy={state.kind === "text"}
          canDownload={state.kind === "text" || state.kind === "binary"}
          canSearch={state.kind === "text"}
          editing={editMode}
          dirty={dirty}
          saving={saving}
          savedFlash={savedFlash}
          truncated={state.kind === "text" && state.file.truncated}
          copied={copied}
          viewMode={viewMode}
          zoom={Math.round((toolKind === "image" ? zoom : zoom) * 100) / 100}
          error={saveError ?? downloadError}
          disabled={pendingFile}
          onViewModeChange={(mode) => { setViewMode(mode); if (mode === "fixed") setZoom(1) }}
          onZoomReset={() => setZoom(1)}
          onEditingChange={handleEmbeddedEditModeChange}
          onRefresh={() => void loadFile()}
          onCopy={copyText}
          onDownload={() => void handleDownload()}
          onSave={() => void handleSave()}
          onSearch={() => editorRef.current?.openSearch()}
        />
      ) : (
      <header
        inert={pendingFile || undefined}
        className={cn(
          "aa-file-preview-header flex min-h-12 shrink-0 items-center gap-2 border-b px-3",
          mode === "embedded"
            ? "aa-file-preview-header-embedded bg-background shadow-none"
            : "bg-sidebar",
        )}
      >
        {mode === "window" ? (
          <div className="aa-file-preview-meta min-w-0 flex-1">
            <div className="truncate text-sm font-medium">{name || t("untitled")}</div>
            <div className="truncate code-mono text-xs text-muted-foreground">{effectivePath}</div>
          </div>
        ) : null}
        <div
          className={cn(
            "aa-file-preview-actions flex items-center gap-1",
            mode === "embedded" ? "min-w-0 flex-1" : "shrink-0",
          )}
        >
          <PreviewBadges state={state} dirty={dirty} saving={saving} savedFlash={savedFlash} saveError={saveError} />
          <Button variant="ghost" size="icon-sm" type="button" aria-label={t("refresh")} onClick={() => void loadFile()}>
            <RotateCw className="size-4" />
          </Button>
          {mode === "window" ? (
            <Button
              className="aa-file-preview-labelled-action"
              variant={editMode ? "secondary" : "ghost"}
              size="sm"
              type="button"
              disabled={state.kind !== "text" || readOnlyPreview}
              onClick={() => {
                if (editMode) {
                  if (dirty) {
                    setSaveError(t("saveBeforeLeavingEdit"))
                    return
                  }
                  setEditMode(false)
                  return
                }
                setEditMode(true)
                window.setTimeout(() => editorRef.current?.focus(), 0)
              }}
            >
              <Edit3 className="size-3.5" />
              <span className="aa-file-preview-action-label">{t("edit")}</span>
            </Button>
          ) : null}
          <Button
            variant="ghost"
            size="icon-sm"
            type="button"
            aria-label={t("search")}
            disabled={state.kind !== "text"}
            onClick={() => editorRef.current?.openSearch()}
          >
            <Search className="size-4" />
          </Button>
          {mode === "window" ? (
            <>
              <Button
                variant="ghost"
                size="icon-sm"
                type="button"
                aria-label={copied ? tCommon("copied") : t("copy")}
                disabled={state.kind !== "text"}
                onClick={copyText}
              >
                {copied ? <Check className="size-4" /> : <Copy className="size-4" />}
              </Button>
              <Button
                variant="ghost"
                size="icon-sm"
                type="button"
                aria-label={t("download")}
                disabled={state.kind !== "text" && state.kind !== "binary"}
                onClick={() => void handleDownload()}
              >
                <Download className="size-4" />
              </Button>
              <Button
                className="aa-file-preview-labelled-action"
                size="sm"
                type="button"
                disabled={readOnlyPreview || state.kind !== "text" || !dirty || saving || !editMode}
                onClick={() => void handleSave()}
              >
                {saving ? <Loader2 className="size-3.5 animate-spin" /> : <Save className="size-3.5" />}
                <span className="aa-file-preview-action-label">{t("save")}</span>
              </Button>
            </>
          ) : null}
          {mode === "embedded" ? (
            <>
              <Button
                variant="ghost"
                size="icon-sm"
                type="button"
                title={t("openWindow")}
                aria-label={t("openWindow")}
                disabled={!onOpenExternal}
                onClick={onOpenExternal}
              >
                <ExternalLink className="size-4" />
              </Button>
              <Label
                htmlFor={embeddedEditModeId}
                className={cn(
                  "ml-auto h-8 shrink-0 cursor-pointer gap-2 rounded-md border border-input bg-background px-2.5 text-xs shadow-xs transition-colors hover:bg-accent hover:text-accent-foreground",
                  editMode && "border-primary/30 bg-primary/10 text-primary hover:bg-primary/15 hover:text-primary",
                  (state.kind !== "text" || readOnlyPreview || saving) && "pointer-events-none cursor-not-allowed opacity-50",
                )}
              >
                <span>{t("edit")}</span>
                <Switch
                  id={embeddedEditModeId}
                  size="sm"
                  checked={editMode}
                  disabled={state.kind !== "text" || readOnlyPreview || saving}
                  aria-label={t("edit")}
                  onCheckedChange={handleEmbeddedEditModeChange}
                />
              </Label>
              <Button
                className="shrink-0"
                size="sm"
                type="button"
                aria-label={t("save")}
                title={t("save")}
                disabled={readOnlyPreview || state.kind !== "text" || !dirty || saving || !editMode}
                onClick={() => void handleSave()}
              >
                {saving ? t("saving") : t("save")}
              </Button>
            </>
          ) : (
            <Button
              variant="ghost"
              size="icon-sm"
              type="button"
              aria-label={t("close")}
              onClick={() => {
                if (dirty) {
                  setSaveError(t("saveBeforeClose"))
                  return
                }
                window.close()
              }}
            >
              <X className="size-4" />
            </Button>
          )}
        </div>
      </header>
      )}
      {!embeddedSkin && downloadError ? (
        <div className="border-b px-3 py-2 text-xs text-destructive">{downloadError}</div>
      ) : null}
      <section ref={contentRef} aria-busy={pendingFile} inert={pendingFile || undefined} className="relative min-h-0 min-w-0 flex-1 overflow-hidden">
        {pendingFile && state.kind === "text" ? (
          <div className="absolute inset-x-0 top-0 z-10 flex justify-center bg-background/80 py-1 text-xs text-muted-foreground">{t("loading")}</div>
        ) : null}
        {state.kind === "loading" ? <CenteredStatus label={t("loading")} /> : null}
        {state.kind === "error" ? (
          embeddedSkin ? (
            <div className="mx-auto flex h-full max-w-md flex-col items-center justify-center px-6 text-center">
              <FileWarning className="size-9 text-[#D92D20]" />
              <div className="mt-3 text-[15px] font-semibold">{t("unavailable")}</div>
              <p className="mt-1 text-sm text-muted-foreground">{state.message}</p>
              <button
                type="button"
                onClick={() => void loadFile()}
                className="mt-5 h-[34px] rounded-[9px] bg-[#F0F0EE] px-4 text-sm font-medium text-[#3A3A38] transition-colors hover:bg-[#E8E8E5]"
              >
                {tCommon("retry")}
              </button>
            </div>
          ) : (
            <div className="mx-auto flex h-full max-w-xl items-center px-6">
              <Alert variant="destructive">
                <FileWarning className="size-4" />
                <AlertTitle>{t("unavailable")}</AlertTitle>
                <AlertDescription>{state.message}</AlertDescription>
              </Alert>
            </div>
          )
        ) : null}
        {state.kind === "text" ? (
          <MonacoCodeView
            documentKey={state.file.path}
            fileName={state.file.name || name}
            content={state.file.content}
            editable={editMode && !readOnlyPreview && !pendingFile}
            theme={embeddedSkin ? "aa-preview-light" : undefined}
            zoom={embeddedSkin ? zoom : 1}
            onReady={handleEditorReady}
            onChange={handleEditorChange}
            className="h-full min-h-0 overflow-hidden"
          />
        ) : null}
        {state.kind === "directory" ? (
          <DirectoryPreview
            directory={state}
            root={root}
            token={token}
            connectorId={connectorId}
            onOpenDirectory={setPath}
            emptyLabel={t("emptyDirectory")}
          />
        ) : null}
        {state.kind === "binary" ? (
          <BinaryPreview
            file={state.file}
            objectUrl={state.objectUrl}
            onDownload={() => void handleDownload()}
            downloading={false}
            zoom={embeddedSkin ? zoom : 1}
          />
        ) : null}
        {embeddedSkin && zoomPill ? (
          <button
            type="button"
            onClick={() => { setZoom(1); setZoomPill(false) }}
            className="absolute bottom-[calc(22px+env(safe-area-inset-bottom))] left-1/2 z-20 -translate-x-1/2 rounded-full bg-black/90 px-3.5 py-1.5 text-xs text-white backdrop-blur-sm"
          >
            {Math.round(zoom * 100)}%
          </button>
        ) : null}
      </section>
    </main>
  )
}

function DirectoryPreview({
  directory,
  root,
  token,
  connectorId,
  onOpenDirectory,
  emptyLabel,
}: {
  directory: Extract<PreviewState, { kind: "directory" }>
  root: string
  token: string | null
  connectorId: string
  onOpenDirectory: (path: string) => void
  emptyLabel: string
}) {
  const parent = parentPath(directory.path)
  const canGoParent = Boolean(parent && isPathInsideRoot(parent, root) && !samePath(parent, directory.path))
  const entries = directory.entries.slice().sort((left, right) => {
    if (left.type === "directory" && right.type !== "directory") return -1
    if (left.type !== "directory" && right.type === "directory") return 1
    return left.name.localeCompare(right.name)
  })

  const openEntry = (entry: FsEntry) => {
    if (entry.type === "directory") {
      onOpenDirectory(entry.path)
      return
    }
    if ((entry.type === "file" || entry.type === "symlink") && token && connectorId) {
      openNativeFilePreviewWindow({
        token,
        connectorId,
        root,
        file: { name: entry.name, path: entry.path },
      })
    }
  }

  return (
    <ScrollArea className="h-full bg-muted/10">
      <div className="mx-auto w-full max-w-4xl p-4">
        {canGoParent ? (
          <button
            type="button"
            className="flex w-full items-center gap-3 border-b px-3 py-2 text-left text-sm hover:bg-muted"
            onClick={() => onOpenDirectory(parent)}
          >
            <FolderOpen className="size-4 text-muted-foreground" />
            <span>..</span>
          </button>
        ) : null}
        {entries.map((entry) => (
          <button
            key={entry.path}
            type="button"
            className="flex w-full items-center gap-3 border-b px-3 py-2 text-left text-sm hover:bg-muted disabled:cursor-not-allowed disabled:opacity-50"
            disabled={entry.type !== "directory" && entry.type !== "file" && entry.type !== "symlink"}
            onClick={() => openEntry(entry)}
          >
            {entry.type === "directory" ? (
              <Folder className="size-4 shrink-0 text-muted-foreground" />
            ) : (
              <File className="size-4 shrink-0 text-muted-foreground" />
            )}
            <span className="min-w-0 flex-1 truncate">{entry.name}</span>
            <span className="text-xs text-muted-foreground">
              {entry.type === "file" && typeof entry.size === "number" ? formatBytes(entry.size) : entry.type}
            </span>
          </button>
        ))}
        {entries.length === 0 ? (
          <div className="px-3 py-10 text-center text-sm text-muted-foreground">{emptyLabel}</div>
        ) : null}
      </div>
    </ScrollArea>
  )
}

function BinaryPreview({
  file,
  objectUrl,
  onDownload,
  zoom = 1,
}: {
  file: BinaryFileInfo
  objectUrl: string | null
  onDownload: () => void
  downloading: boolean
  zoom?: number
}) {
  const t = useTranslations("preview")
  const kind = previewKind(file.mediaType, file.name)
  if (objectUrl && kind === "image") {
    return (
      <div className="size-full min-h-0 min-w-0 overflow-auto bg-muted/20 p-4">
        <ZoomFrame zoom={zoom}>
          <img src={objectUrl} alt={file.name} className="block size-full object-contain" />
        </ZoomFrame>
      </div>
    )
  }
  if (objectUrl && kind === "video") {
    return <div className="flex size-full min-h-0 min-w-0 items-center justify-center overflow-hidden bg-black p-4"><video src={objectUrl} controls className="block max-h-full max-w-full object-contain" /></div>
  }
  if (objectUrl && kind === "audio") {
    return <div className="flex size-full min-h-0 min-w-0 items-center justify-center overflow-hidden p-8"><audio src={objectUrl} controls className="w-full max-w-2xl" /></div>
  }
  if (objectUrl && kind === "pdf") {
    return (
      <div className="size-full min-h-0 min-w-0 overflow-auto bg-[#ECECEA]">
        <ZoomFrame zoom={zoom}>
          <iframe src={objectUrl} title={file.name} className="block size-full border-0" />
        </ZoomFrame>
      </div>
    )
  }
  return (
    <div className="flex h-full items-center justify-center p-6">
      <div className="flex max-w-md flex-col items-center gap-3 text-center">
        <FileWarning className="size-10 text-muted-foreground" />
        <div>
          <div className="font-medium">{t("binaryUnavailable")}</div>
          <div className="mt-1 text-sm text-muted-foreground">
            {file.mediaType || "application/octet-stream"} · {formatBytes(file.size)}
          </div>
        </div>
        <Button
          type="button"
          onClick={onDownload}
          className="bg-[#F0F0EE] text-[#3A3A38] hover:bg-[#E8E8E5]"
        >
          <Download className="size-4" />
          {t("download")}
        </Button>
      </div>
    </div>
  )
}

function PreviewBadges({
  state,
  dirty,
  saving,
  savedFlash,
  saveError,
}: {
  state: PreviewState
  dirty: boolean
  saving: boolean
  savedFlash: boolean
  saveError: string | null
}) {
  const t = useTranslations("preview")
  if (saveError) return <Badge variant="destructive" className="max-w-56 truncate">{saveError}</Badge>
  if (saving) return <Badge variant="secondary">{t("saving")}</Badge>
  if (dirty) return <Badge variant="secondary">{t("unsaved")}</Badge>
  if (savedFlash) return <Badge variant="secondary">{t("saved")}</Badge>
  if (state.kind === "text" && state.file.truncated) return <Badge variant="secondary">{t("truncated")}</Badge>
  return null
}

function CenteredStatus({ label }: { label: string }) {
  return (
    <div className="flex h-full items-center justify-center gap-2 text-sm text-muted-foreground">
      <Spinner />
      {label}
    </div>
  )
}

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = filename || "download"
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  window.setTimeout(() => URL.revokeObjectURL(url), 0)
}

function canBrowserPreview(mediaType: string, name: string) {
  const kind = previewKind(mediaType, name)
  return kind === "image" || kind === "video" || kind === "audio" || kind === "pdf"
}

function canTextPreview(mediaType: string, name: string) {
  const type = mediaType.toLowerCase().split(";", 1)[0]?.trim() ?? ""
  if (type.startsWith("text/")) return true
  if (
    type === "application/json"
    || type === "application/ld+json"
    || type === "application/javascript"
    || type === "application/xml"
    || type === "application/x-httpd-php"
    || type === "application/x-sh"
    || type === "application/x-yaml"
  ) return true

  const lowerName = name.toLowerCase()
  if (
    [".env", ".gitignore", ".gitattributes", ".npmrc", ".yarnrc", ".zshrc", ".bashrc"]
      .includes(lowerName)
  ) {
    return true
  }
  return /\.(?:c|cc|conf|cpp|cs|css|csv|go|h|hpp|html?|ini|java|js|jsx|json|jsonl|kt|kts|log|lua|md|mdx|mjs|mts|php|properties|py|rb|rs|scss|sh|sql|svelte|swift|toml|ts|tsx|txt|vue|xml|ya?ml|zsh)$/
    .test(lowerName)
}

function resolvedPreviewMediaType(declaredType: string, responseType: string, name: string) {
  const declared = declaredType.trim()
  if (declared && declared !== "application/octet-stream") return declared
  const response = responseType.trim()
  if (response && response !== "application/octet-stream") return response
  return mediaTypeForFile(name)
}

function previewKind(mediaType: string, name: string): "image" | "video" | "audio" | "pdf" | "binary" {
  const type = mediaType.toLowerCase()
  const lowerName = name.toLowerCase()
  if (type.startsWith("image/")) return "image"
  if (type.startsWith("video/")) return "video"
  if (type.startsWith("audio/")) return "audio"
  if (type === "application/pdf" || lowerName.endsWith(".pdf")) return "pdf"
  return "binary"
}

function mediaTypeForFile(name: string) {
  const lower = name.toLowerCase()
  if (/\.(png|apng|jpg|jpeg|gif|webp|avif|svg)$/.test(lower)) return `image/${lower.endsWith(".svg") ? "svg+xml" : lower.split(".").pop()}`
  if (/\.(mp4|webm|ogg|mov)$/.test(lower)) return lower.endsWith(".mov") ? "video/quicktime" : `video/${lower.split(".").pop()}`
  if (/\.(mp3|wav|oga|m4a|flac)$/.test(lower)) return `audio/${lower.split(".").pop()}`
  if (lower.endsWith(".pdf")) return "application/pdf"
  return "application/octet-stream"
}

function fileNameFromPath(path: string) {
  const normalized = path.replace(/\\/g, "/").replace(/\/+$/, "")
  return normalized.split("/").pop() || path || "preview"
}

function samePath(left: string, right: string) {
  return normalizePath(left) === normalizePath(right)
}

function parentPath(path: string) {
  const normalized = normalizePath(path)
  const slash = normalized.lastIndexOf("/")
  if (slash < 0) return ""
  if (slash === 0) return "/"
  return normalized.slice(0, slash)
}

function isPathInsideRoot(path: string, root: string) {
  const normalizedPath = normalizePath(path)
  const normalizedRoot = normalizePath(root)
  return normalizedPath === normalizedRoot || normalizedPath.startsWith(`${normalizedRoot}/`)
}

function normalizePath(path: string) {
  const normalized = path.replace(/\\/g, "/").replace(/\/+$/, "")
  return /^[A-Za-z]:/.test(normalized) ? normalized.toLowerCase() : normalized || "/"
}

// CSS `zoom` did not scale images/PDFs inside WKWebView, so reserve the scaled
// box and transform the original layout into it. The scroll container then has
// the right scrollable area (pp 2026-11-22).
function ZoomFrame({ zoom, children }: { zoom: number; children: React.ReactNode }) {
  return (
    <div style={{ width: `${zoom * 100}%`, height: `${zoom * 100}%` }}>
      <div
        style={{
          width: `${100 / zoom}%`,
          height: `${100 / zoom}%`,
          transform: `scale(${zoom})`,
          transformOrigin: "top left",
        }}
      >
        {children}
      </div>
    </div>
  )
}

function formatBytes(size: number) {
  if (size < 1024) return `${size} B`
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`
  return `${(size / 1024 / 1024).toFixed(1)} MB`
}
