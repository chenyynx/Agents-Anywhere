"use client"

import * as React from "react"
import {
  Check,
  Copy,
  Download,
  Edit3,
  RotateCw,
  Search,
} from "lucide-react"
import { useTranslations } from "next-intl"

import { cn } from "@/lib/utils"

type EmbeddedPreviewHeaderProps = {
  name: string
  path: string
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
  error: string | null
  disabled: boolean
  onEditingChange: (editing: boolean) => void
  onRefresh: () => void
  onCopy: () => void
  onDownload: () => void
  onSave: () => void
  onSearch: () => void
}

// Flat white toolbar, same shape as the original preview header: file name and
// path on the left, all file actions on the right. No cards, no path popover
// (pp 2026-11-22).
export function EmbeddedPreviewHeader({
  name,
  path,
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
  error,
  disabled,
  onEditingChange,
  onRefresh,
  onCopy,
  onDownload,
  onSave,
  onSearch,
}: EmbeddedPreviewHeaderProps) {
  const t = useTranslations("preview")
  const tCommon = useTranslations("common")

  return (
    <div className="shrink-0">
      <div
        inert={disabled || undefined}
        className="aa-preview-toolbar flex min-h-14 items-center gap-2 border-b px-3 py-1.5"
      >
        <div className="flex min-w-0 flex-1 flex-col gap-px">
          <div className="flex min-w-0 items-center gap-1.5">
            <span className="truncate text-sm font-medium">{name || t("untitled")}</span>
            {dirty ? <span className="size-1.5 shrink-0 rounded-full bg-[#FF9F0A]" aria-label={t("unsaved")} /> : null}
            {truncated ? (
              <span className="shrink-0 rounded-[5px] bg-muted px-1.5 py-px text-[10px] leading-4 text-muted-foreground">
                {t("truncated")}
              </span>
            ) : null}
          </div>
          <div className="truncate font-mono text-[11px] leading-4 text-muted-foreground" title={path}>{path}</div>
        </div>

        <div className="flex shrink-0 items-center gap-0.5">
          <IconAction label={t("refresh")} onClick={onRefresh} disabled={disabled}>
            <RotateCw className="size-[17px]" />
          </IconAction>
          <button
            type="button"
            aria-label={t("edit")}
            aria-pressed={editing}
            disabled={disabled || !canEdit}
            onClick={() => onEditingChange(!editing)}
            className={cn(
              "flex h-8 shrink-0 items-center gap-1.5 rounded-lg px-2.5 text-[13px] transition-colors hover:bg-accent disabled:pointer-events-none disabled:opacity-30",
              editing && "bg-accent",
            )}
          >
            <Edit3 className="size-3.5" />
            <span>{t("edit")}</span>
          </button>
          <IconAction label={t("search")} onClick={onSearch} disabled={disabled || !canSearch}>
            <Search className="size-[17px]" />
          </IconAction>
          <IconAction
            label={copied ? tCommon("copied") : t("copy")}
            onClick={onCopy}
            disabled={disabled || !canCopy}
          >
            {copied ? <Check className="size-[17px] text-emerald-600" /> : <Copy className="size-[17px]" />}
          </IconAction>
          <IconAction label={t("download")} onClick={onDownload} disabled={disabled || !canDownload}>
            <Download className="size-[17px]" />
          </IconAction>
          <button
            type="button"
            aria-label={t("save")}
            disabled={disabled || !editing || !dirty || saving}
            onClick={onSave}
            className="flex h-8 min-w-13 shrink-0 items-center justify-center rounded-lg bg-foreground px-3 text-[13px] font-medium text-background transition-colors hover:bg-foreground/90 disabled:bg-muted disabled:text-muted-foreground"
          >
            {saving ? t("saving") : savedFlash ? t("saved") : t("save")}
          </button>
        </div>
      </div>
      {error ? (
        <div role="alert" className="aa-preview-banner mx-3 mt-2 rounded-[10px] bg-destructive/10 px-3 py-2 text-xs leading-relaxed text-destructive">
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
  children,
}: {
  label: string
  onClick: () => void
  disabled?: boolean
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
      className="flex size-9 shrink-0 items-center justify-center rounded-[9px] transition-colors hover:bg-accent disabled:pointer-events-none disabled:opacity-30"
    >
      {children}
    </button>
  )
}
