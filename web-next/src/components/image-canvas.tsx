"use client"

import * as React from "react"

import { cn } from "@/lib/utils"

// Free-canvas image viewer: the bitmap floats on the grey surface and can be
// dragged anywhere, with pinch zoom anchored at the fingers. No scroll
// container, no bounds — the demo's "infinite canvas" feel (pp 2026-11-23).
type ImageCanvasProps = {
  src: string
  alt: string
  zoom: number
  fixed?: boolean
  onZoomChange?: (zoom: number) => void
  className?: string
  testId?: string
}

const MIN_ZOOM = 0.25
const MAX_ZOOM = 6
const EDGE_PADDING = 16

function clampZoom(value: number) {
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value))
}

export function ImageCanvas({
  src,
  alt,
  zoom,
  fixed = false,
  onZoomChange,
  className,
  testId,
}: ImageCanvasProps) {
  const containerRef = React.useRef<HTMLDivElement | null>(null)
  const [container, setContainer] = React.useState({ width: 0, height: 0 })
  const [natural, setNatural] = React.useState({ width: 0, height: 0 })
  const [offset, setOffset] = React.useState({ x: 0, y: 0 })

  const offsetRef = React.useRef(offset)
  const zoomRef = React.useRef(zoom)
  const fixedRef = React.useRef(fixed)
  const lastReportedZoomRef = React.useRef(zoom)
  const onZoomChangeRef = React.useRef(onZoomChange)

  React.useEffect(() => {
    offsetRef.current = offset
  }, [offset])
  React.useEffect(() => {
    fixedRef.current = fixed
  }, [fixed])
  React.useEffect(() => {
    onZoomChangeRef.current = onZoomChange
  }, [onZoomChange])

  React.useEffect(() => {
    if (!src) return
    let cancelled = false
    const image = document.createElement("img")
    image.onload = () => {
      if (!cancelled) setNatural({ width: image.naturalWidth, height: image.naturalHeight })
    }
    image.src = src
    return () => {
      cancelled = true
      image.onload = null
    }
  }, [src])

  React.useEffect(() => {
    const node = containerRef.current
    if (!node) return
    const measure = () => {
      const rect = node.getBoundingClientRect()
      setContainer({ width: rect.width, height: rect.height })
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(node)
    return () => observer.disconnect()
  }, [])

  // The bitmap is laid out at its fitted size; zoom is relative to that fit.
  const base = React.useMemo(() => {
    if (!natural.width || !natural.height || !container.width || !container.height) return null
    const fit = Math.min(
      Math.max(1, container.width - EDGE_PADDING * 2) / natural.width,
      Math.max(1, container.height - EDGE_PADDING * 2) / natural.height,
    )
    return { width: natural.width * fit, height: natural.height * fit }
  }, [natural, container])

  // Re-centre when the fitted bitmap or the viewport changes.
  React.useEffect(() => {
    if (!base) return
    setOffset({
      x: (container.width - base.width * zoomRef.current) / 2,
      y: (container.height - base.height * zoomRef.current) / 2,
    })
  }, [base, container.width, container.height])

  // Fixed mode locks the bitmap back to its centred fit.
  React.useEffect(() => {
    if (!fixed || !base) return
    setOffset({
      x: (container.width - base.width * zoom) / 2,
      y: (container.height - base.height * zoom) / 2,
    })
  }, [fixed, base, container.width, container.height, zoom])

  // Toolbar zoom (menu / reset) anchors at the viewport centre. Pinch changes
  // report through the same prop, so skip the echo and only apply external moves.
  React.useEffect(() => {
    if (Math.abs(zoom - lastReportedZoomRef.current) < 0.001) return
    lastReportedZoomRef.current = zoom
    const previous = zoomRef.current
    zoomRef.current = zoom
    if (!base || fixedRef.current) return
    const ratio = zoom / previous
    setOffset(current => {
      const cx = container.width / 2
      const cy = container.height / 2
      return { x: cx - (cx - current.x) * ratio, y: cy - (cy - current.y) * ratio }
    })
  }, [zoom, base, container.width, container.height])

  React.useEffect(() => {
    const node = containerRef.current
    if (!node) return

    let pan: { pointerX: number; pointerY: number; x: number; y: number } | null = null
    let pinch: { distance: number; zoom: number; x: number; y: number; rect: DOMRect } | null = null
    let gesture: { zoom: number; x: number; y: number; rect: DOMRect } | null = null

    const distance = (touches: TouchList) => {
      const first = touches[0]
      const second = touches[1]
      return first && second ? Math.hypot(first.clientX - second.clientX, first.clientY - second.clientY) : 0
    }

    const report = (next: number) => {
      lastReportedZoomRef.current = next
      zoomRef.current = next
      onZoomChangeRef.current?.(next)
    }

    const onStart = (event: TouchEvent) => {
      if (fixedRef.current) return
      if (event.touches.length === 1) {
        const touch = event.touches[0]
        if (!touch) return
        pan = {
          pointerX: touch.clientX,
          pointerY: touch.clientY,
          x: offsetRef.current.x,
          y: offsetRef.current.y,
        }
        pinch = null
        gesture = null
      } else if (event.touches.length === 2 && !gesture) {
        pinch = {
          distance: distance(event.touches),
          zoom: zoomRef.current,
          x: offsetRef.current.x,
          y: offsetRef.current.y,
          rect: node.getBoundingClientRect(),
        }
        pan = null
      }
    }

    const onMove = (event: TouchEvent) => {
      if (fixedRef.current || gesture) return
      if (pinch && event.touches.length === 2) {
        event.preventDefault()
        const first = event.touches[0]
        const second = event.touches[1]
        const spread = distance(event.touches)
        if (!first || !second || !pinch.distance || !spread) return
        const next = clampZoom((pinch.zoom * spread) / pinch.distance)
        const midX = (first.clientX + second.clientX) / 2 - pinch.rect.left
        const midY = (first.clientY + second.clientY) / 2 - pinch.rect.top
        const ratio = next / pinch.zoom
        setOffset({
          x: midX - (midX - pinch.x) * ratio,
          y: midY - (midY - pinch.y) * ratio,
        })
        report(next)
      } else if (pan && event.touches.length === 1) {
        event.preventDefault()
        const touch = event.touches[0]
        if (!touch) return
        setOffset({
          x: pan.x + touch.clientX - pan.pointerX,
          y: pan.y + touch.clientY - pan.pointerY,
        })
      }
    }

    const onEnd = (event: TouchEvent) => {
      if (event.touches.length === 0) {
        pan = null
        pinch = null
      } else if (event.touches.length === 1 && !gesture) {
        const touch = event.touches[0]
        if (!touch) return
        pinch = null
        pan = {
          pointerX: touch.clientX,
          pointerY: touch.clientY,
          x: offsetRef.current.x,
          y: offsetRef.current.y,
        }
      }
    }

    // iOS WebKit reports two-finger pinches as gesture* events and may keep
    // touchmove for itself; handle both, with touch input standing down while
    // a gesture is in flight.
    const onGestureStart = (event: Event) => {
      event.preventDefault()
      if (fixedRef.current) return
      gesture = {
        zoom: zoomRef.current,
        x: offsetRef.current.x,
        y: offsetRef.current.y,
        rect: node.getBoundingClientRect(),
      }
      pinch = null
    }
    const onGestureChange = (event: Event) => {
      event.preventDefault()
      if (!gesture) return
      const scale = Number((event as Event & { scale?: number }).scale)
      if (!Number.isFinite(scale) || scale <= 0) return
      const focal = event as Event & { clientX?: number; clientY?: number }
      const next = clampZoom(gesture.zoom * scale)
      const ratio = next / gesture.zoom
      const focalX = (focal.clientX ?? gesture.rect.left + gesture.rect.width / 2) - gesture.rect.left
      const focalY = (focal.clientY ?? gesture.rect.top + gesture.rect.height / 2) - gesture.rect.top
      setOffset({
        x: focalX - (focalX - gesture.x) * ratio,
        y: focalY - (focalY - gesture.y) * ratio,
      })
      report(next)
    }
    const onGestureEnd = (event: Event) => {
      event.preventDefault()
      gesture = null
    }

    node.addEventListener("touchstart", onStart, { passive: true })
    node.addEventListener("touchmove", onMove, { passive: false })
    node.addEventListener("touchend", onEnd, { passive: true })
    node.addEventListener("touchcancel", onEnd, { passive: true })
    node.addEventListener("gesturestart", onGestureStart, { capture: true, passive: false })
    node.addEventListener("gesturechange", onGestureChange, { capture: true, passive: false })
    node.addEventListener("gestureend", onGestureEnd, { capture: true, passive: false })
    return () => {
      node.removeEventListener("touchstart", onStart)
      node.removeEventListener("touchmove", onMove)
      node.removeEventListener("touchend", onEnd)
      node.removeEventListener("touchcancel", onEnd)
      node.removeEventListener("gesturestart", onGestureStart, { capture: true })
      node.removeEventListener("gesturechange", onGestureChange, { capture: true })
      node.removeEventListener("gestureend", onGestureEnd, { capture: true })
    }
  }, [])

  return (
    <div
      ref={containerRef}
      data-testid={testId}
      className={cn(
        "relative size-full min-h-0 min-w-0 touch-none select-none overflow-hidden",
        className,
      )}
    >
      {base ? (
        <div
          data-testid="preview-image-canvas-content"
          className="absolute left-0 top-0 will-change-transform"
          style={{
            width: base.width,
            height: base.height,
            transform: `translate3d(${offset.x}px, ${offset.y}px, 0) scale(${zoom})`,
            transformOrigin: "0 0",
          }}
        >
          <img src={src} alt={alt} draggable={false} className="block size-full select-none" />
        </div>
      ) : null}
    </div>
  )
}
