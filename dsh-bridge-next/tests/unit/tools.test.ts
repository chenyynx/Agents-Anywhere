import test from 'node:test'
import assert from 'node:assert/strict'
import { toolContent } from '../../src/host/dsh-runtime/tools.js'

test('DSH delegation tools mark the background hand-off; control tools never do', () => {
  // subagent is the continuable delegation tool and subagent_fork is the same
  // tool bound to the fork backend; both start a child that keeps running in
  // the background (official tools reference). Clients seal the reply that
  // precedes a background hand-off on this flag (pp 2026-11-18).
  const delegation: Array<[string, string]> = [['subagent', 'invoke'], ['subagent_fork', 'spawn']]
  for (const [name, action] of delegation) {
    const content = toolContent(name, { prompt: 'inspect the repo', target: 'agent-1' })
    assert.equal(content.kind, 'agent_call')
    assert.equal(content.action, action)
    assert.equal(content.runInBackground, true)
  }
  // Messaging, waiting, listing and interrupting manage children that already
  // run; they are ordinary foreground steps and must not hand the turn off.
  const control: Array<[string, string]> = [
    ['send_message', 'send_input'], ['wait_agent', 'wait'],
    ['interrupt_agent', 'close'], ['list_agents', 'unknown'],
  ]
  for (const [name, action] of control) {
    const content = toolContent(name, { target: 'agent-1' })
    assert.equal(content.kind, 'agent_call')
    assert.equal(content.action, action)
    assert.equal('runInBackground' in content, false)
  }
  // Bash stays unmarked: this wire reports no background mode for commands.
  const bash = toolContent('bash', { command: 'sleep 1' })
  assert.equal(bash.kind, 'command')
  assert.equal('runInBackground' in bash, false)
})
