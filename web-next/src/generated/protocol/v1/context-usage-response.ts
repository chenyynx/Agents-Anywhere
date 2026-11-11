/* eslint-disable */
/**
 * Generated from protocol 1.0 artifact context-usage-response.
 * Do not edit by hand; run `yarn protocol:generate`.
 */

export type Servertime = string
export type Agenttype = string
export type Source = string | null
export type Tokens = number
export type Agents = ProtocolContextUsageAgent[]
export type Kind = string | null
export type Name = string
export type Tokens1 = number
export type Categories = ProtocolContextUsageCategory[]
export type Detail = string
export type Maxtokens = number | null
export type Name1 = string
export type Servername = string
export type Tokens2 = number
export type Mcptools = ProtocolContextUsageMcpTool[]
export type Measuredat = string | null
export type Path = string
export type Tokens3 = number
export type Type = string | null
export type Memoryfiles = ProtocolContextUsageMemoryFile[]
export type Model = string | null
export type Percentage = number | null
export type Runtime = "codex" | "claude" | "opencode" | "acp" | "dsh"
export type Name2 = string
export type Pluginname = string | null
export type Source1 = string | null
export type Tokens4 = number
export type Skills = ProtocolContextUsageSkill[]
export type Source2 = string
export type Totaltokens = number

export interface ProtocolContextUsageResponse {
  serverTime: Servertime
  usage: ProtocolContextUsage
  [k: string]: unknown
}
/**
 * One runtime's context-window answer.
 *
 * Detail lists are empty for runtimes that report only used/max (codex); the
 * client renders the summary and hides the breakdown section in that case.
 */
export interface ProtocolContextUsage {
  agents: Agents
  categories: Categories
  detail: Detail
  maxTokens: Maxtokens
  mcpTools: Mcptools
  measuredAt: Measuredat
  memoryFiles: Memoryfiles
  model: Model
  percentage: Percentage
  runtime: Runtime
  skills: Skills
  source: Source2
  totalTokens: Totaltokens
  [k: string]: unknown
}
export interface ProtocolContextUsageAgent {
  agentType: Agenttype
  source: Source
  tokens: Tokens
  [k: string]: unknown
}
export interface ProtocolContextUsageCategory {
  kind: Kind
  name: Name
  tokens: Tokens1
  [k: string]: unknown
}
export interface ProtocolContextUsageMcpTool {
  name: Name1
  serverName: Servername
  tokens: Tokens2
  [k: string]: unknown
}
export interface ProtocolContextUsageMemoryFile {
  path: Path
  tokens: Tokens3
  type: Type
  [k: string]: unknown
}
export interface ProtocolContextUsageSkill {
  name: Name2
  pluginName: Pluginname
  source: Source1
  tokens: Tokens4
  [k: string]: unknown
}
