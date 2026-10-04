import assert from 'node:assert/strict'
import test from 'node:test'
import { registerSource } from './helpers/onboarding-source.mjs'

const hook = registerSource()
const { runtimeErrorCopyKey } = await import('../src/components/session/runtime-error-copy.ts')
hook.deregister()

// The retired-process disclosure must reach the user as copy, not as the
// Connector's English wire message — and the codes this build has never
// heard of must keep reading as something a person can act on.
test('the retirement code has copy', () => {
  assert.equal(runtimeErrorCopyKey('claude_process_retired'), 'claudeProcessRetired')
})

// The old timeout code is a DIFFERENT incident (no close happened), and its
// wording is still correct. Mapping it here would silently rewrite a
// sentence that was never the defect.
test('the timeout code keeps the Connector own wording', () => {
  assert.equal(runtimeErrorCopyKey('claude_scheduled_turn_timeout'), null)
})

// The contract with every future code: keep today's behaviour, which is the
// generic error surface — never an empty string, never a serialized payload.
test('an unknown code has no copy', () => {
  assert.equal(runtimeErrorCopyKey('code_from_a_newer_connector'), null)
  assert.equal(runtimeErrorCopyKey(''), null)
  assert.equal(runtimeErrorCopyKey(undefined), null)
  assert.equal(runtimeErrorCopyKey(null), null)
  assert.equal(runtimeErrorCopyKey(42), null)
})

test('every mapped key exists in every shipped locale', async () => {
  const locales = ['en', 'zh-CN']
  for (const locale of locales) {
    const messages = JSON.parse(
      await (await import('node:fs/promises')).readFile(new URL(`../messages/${locale}.json`, import.meta.url), 'utf8'),
    )
    for (const code of ['claude_process_retired']) {
      const key = runtimeErrorCopyKey(code)
      assert.notEqual(key, null, `${code} has no copy`)
      assert.equal(typeof messages.dashboard.session[key], 'string', `${locale} is missing ${key}`)
      assert.ok(messages.dashboard.session[key].length > 0, `${locale} has empty ${key}`)
    }
  }
})