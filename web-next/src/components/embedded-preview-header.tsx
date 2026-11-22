"use client"

import * as React from "react"
import {
  Check,
  ChevronDown,
  Copy,
  Download,
  Edit3,
  Lock,
  MoreHorizontal,
  RotateCw,
  Search,
  ZoomIn,
} from "lucide-react"
import { useTranslations } from "next-intl"

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { cn } from "@/lib/utils"

type PreviewKind = "code" | "image" | "pdf" | "other"

type EmbeddedPreviewHeaderProps = {
  kind: PreviewKind
  canEdit: boolean
  canCopy: boolean
  canDownload: boolean
  canSearch: boolean
  editing: boolean
  dirty: boolean
  saving: boolean
  savedFlash: boolean
  truncated: boolean
  copied: boolean
  viewMode: "zoom" | "fixed"
  zoom: number
  error: string | null
  disabled: boolean
  onEditingChange: (editing: boolean) => void
  onViewModeChange: (mode: "zoom" | "fixed") => void
  onZoomChange: (zoom: number) => void
  onRefresh: () => void
  onCopy: () => void
  onCopyPath: () => void
  onDownload: () => void
  onSave: () => void
  onSearch: () => void
}

// The app preview toolbar: two content-sized white cards on the paper-grey
// strip. Left card holds view controls (or edit/search for code); the right
// card holds file actions and the zoom readout. No file name or path — the
// native navigation bar already shows the title (pp 2026-11-23).
export function EmbeddedPreviewHeader({
  kind,
  canEdit,
  canCopy,
  canDownload,
  canSearch,
  editing,
  dirty,
  saving,
  savedFlash,
  truncated,
  copied,
  viewMode,
  zoom,
  error,
  disabled,
  onEditingChange,
  onViewModeChange,
  onZoomChange,
  onRefresh,
  onCopy,
  onCopyPath,
  onDownload,
  onSave,
  onSearch,
}: EmbeddedPreviewHeaderProps) {
  const t = useTranslations("preview")
  const tCommon = useTranslations("common")
  const media = kind === "image" || kind === "pdf"
  const canZoom = kind === "code" || media

  return (
    <div className="shrink-0">
      <div inert={disabled || undefined} className="flex items-center justify-center gap-[18px] bg-[#ECECEA] px-2 py-2.5">
        <div className="flex h-[46px] items-center gap-1 rounded-[10px] border-[1.1px] border-[rgba(0,0,0,0.21)] bg-white px-2.5 shadow-[0_4px_10px_rgba(0,0,0,0.04),0_4px_18px_rgba(0,0,0,0.04)]">
          {media ? (
            <div className="flex items-center gap-1.5">
              <button
                type="button"
                onClick={() => onViewModeChange(viewMode === "zoom" ? "fixed" : "zoom")}
                className={cn(
                  "flex h-8 items-center gap-1 pl-0.5 pr-1 text-[15px] transition-colors",
                  viewMode === "zoom" ? "text-[#3A3A38]" : "text-[#8A8A86]",
                )}
              >
                {viewMode === "zoom" ? t("zoomMode") : t("fixedMode")}
                <ChevronDown className="size-2.5 text-[#82827F]" />
              </button>
              <span className="h-5 w-px shrink-0 bg-[#E4E4E4]" aria-hidden="true" />
              <button
                type="button"
                aria-label={t("zoomMode")}
                aria-pressed={viewMode === "zoom"}
                onClick={() => onViewModeChange("zoom")}
                className={cn(
                  "grid size-[30px] place-items-center rounded-[9px] text-[#8A8A86] transition-colors",
                  viewMode === "zoom" && "bg-[#F0F0EE] text-[#3A3A38]",
                )}
              >
                <ZoomIn className="size-3.5" />
              </button>
              <button
                type="button"
                aria-label={t("fixedMode")}
                aria-pressed={viewMode === "fixed"}
                onClick={() => onViewModeChange("fixed")}
                className={cn(
                  "grid size-[30px] place-items-center rounded-[9px] text-[#8A8A86] transition-colors",
                  viewMode === "fixed" && "bg-[#F0F0EE] text-[#0A0A0A]",
                )}
              >
                <Lock className="size-3.5" />
              </button>
            </div>
          ) : (
            <>
              <IconAction label={t("refresh")} onClick={onRefresh} disabled={disabled}>
                <RotateCw className="size-3.5" />
              </IconAction>
              <IconAction
                label={t("edit")}
                onClick={() => onEditingChange(!editing)}
                disabled={disabled || !canEdit}
                className={editing ? "bg-[#F0F0EE] text-[#0A84FF]" : undefined}
              >
                <Edit3 className="size-3.5" />
              </IconAction>
              <span className="mx-0.5 h-5 w-px shrink-0 bg-[#E4E4E4]" aria-hidden="true" />
              <IconAction label={t("search")} onClick={onSearch} disabled={disabled || !canSearch}>
                <Search className="size-3.5" />
              </IconAction>
            </>
          )}
        </div>

        <div className="flex h-[46px] items-center gap-1 rounded-[10px] border-[1.1px] border-[rgba(0,0,0,0.21)] bg-white px-2.5 shadow-[0_4px_10px_rgba(0,0,0,0.04),0_4px_18px_rgba(0,0,0,0.04)]">
          {kind !== "image" && kind !== "pdf" ? (
            <IconAction
              label={copied ? tCommon("copied") : t("copy")}
              onClick={onCopy}
              disabled={disabled || !canCopy}
            >
              {copied ? <Check className="size-3.5 text-emerald-600" /> : <Copy className="size-3.5" />}
            </IconAction>
          ) : null}
          <IconAction label={t("download")} onClick={onDownload} disabled={disabled || !canDownload}>
            <Download className="size-3.5" />
          </IconAction>
          {media ? (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button
                  type="button"
                  aria-label={t("more")}
                  disabled={disabled}
                  className="grid size-8 shrink-0 place-items-center rounded-[9px] text-[#0A0A0A] transition-colors hover:bg-[#F2F2F0] disabled:pointer-events-none disabled:opacity-30"
                >
                  <MoreHorizontal className="size-3.5" />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent
                align="end"
                className="min-w-40 bg-white! text-[#0A0A0A]! ring-black/10!"
              >
                <DropdownMenuItem
                  disabled={disabled}
                  onSelect={() => onRefresh()}
                  className="focus:bg-[#F2F2F0]! focus:text-[#0A0A0A]!"
                >
                  <RotateCw className="size-3.5" />
                  {t("refresh")}
                </DropdownMenuItem>
                <DropdownMenuItem
                  disabled={disabled}
                  onSelect={() => onCopyPath()}
                  className="focus:bg-[#F2F2F0]! focus:text-[#0A0A0A]!"
                >
                  <Copy className="size-3.5" />
                  {t("copyPath")}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          ) : null}
          {kind === "code" || kind === "other" ? (
            <button
              type="button"
              aria-label={t("save")}
              disabled={disabled || !editing || !dirty || saving}
              onClick={onSave}
              className="h-8 min-w-0 shrink-0 rounded-[9px] px-1 text-[15px] font-normal text-[#0A0A0A] transition-colors disabled:text-[#B5B5B0]"
            >
              {saving ? t("saving") : savedFlash ? t("saved") : t("save")}
            </button>
          ) : null}
          {canZoom ? (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button
                  type="button"
                  aria-label={t("zoomLevel")}
                  disabled={disabled || viewMode === "fixed"}
                  className="flex h-8 min-w-[46px] items-center justify-end gap-1 pr-0.5 text-[15px] text-[#0A0A0A] tabular-nums transition-colors disabled:text-[#B5B5B0]"
                >
                  {Math.round(zoom * 100)}%
                  <ChevronDown className="size-2.5 text-[#82827F]" />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent
                align="end"
                className="min-w-28 bg-white! text-[#0A0A0A]! ring-black/10!"
              >
                <DropdownMenuRadioGroup
                  value={String(Math.round(zoom * 100))}
                  onValueChange={(value) => onZoomChange(Number(value) / 100)}
                >
                  {[50, 75, 100, 125, 150, 200].map((percent) => (
                    <DropdownMenuRadioItem
                      key={percent}
                      value={String(percent)}
                      className="focus:bg-[#F2F2F0]! focus:text-[#0A0A0A]!"
                    >
                      {percent}%
                    </DropdownMenuRadioItem>
                  ))}
                </DropdownMenuRadioGroup>
              </DropdownMenuContent>
            </DropdownMenu>
          ) : null}
          {truncated ? (
            <span className="ml-1 shrink-0 rounded-[5px] bg-[#F2F2F0] px-1.5 py-px text-[10px] leading-4 text-[#82827F]">
              {t("truncated")}
            </span>
          ) : null}
        </div>
      </div>
      {error ? (
        <div role="alert" className="mx-3 mb-2 rounded-[10px] bg-destructive/10 px-3 py-2 text-xs leading-relaxed text-destructive">
          {error}
        </div>
      ) : null}
    </div>
  )
}

function IconAction({
  label,
  onClick,
  disabled,
  className,
  children,
}: {
  label: string
  onClick: () => void
  disabled?: boolean
  className?: string
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
      className={cn(
        "grid size-8 shrink-0 place-items-center rounded-[9px] text-[#0A0A0A] transition-colors hover:bg-[#F2F2F0] disabled:pointer-events-none disabled:opacity-30",
        className,
      )}
    >
      {children}
    </button>
  )
}
