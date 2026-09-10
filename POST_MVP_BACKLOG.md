# qai-voice Post-MVP Backlog

This file is the source of truth for work after the v0.1 dictation loop. Work on one unchecked item at a time. Before editing, inspect the current implementation, propose a plan, add or update meaningful tests, run the Xcode test suite, and update this file when the item is complete.

## Recommended implementation order

- [ ] **P0 — Transcript recovery:** copy and reinsert a transcript after the original focused app has no text field.
- [ ] **P1 — Recording status overlay:** show a clear, non-focus-stealing animation while recording and transcribing.
- [ ] **P2 — Default developer vocabulary pack:** add QA, IT, cloud, security, and AI terms as recognition hints and safe corrections.
- [ ] **P3 — Recent transcript history:** retain the last 10–20 transcripts for copy, reinsert, delete, and clear actions.
- [ ] **P4 — Terminal-aware formatting:** improve paths, flags, package names, URLs, punctuation, and spoken “new line” handling.
- [ ] **P5 — Engine benchmark:** compare Apple Speech, local Whisper, and Parakeet on the same recordings.
- [ ] **P6 — Optional speech engines:** add another engine only when benchmarks show a meaningful improvement.
- [ ] **P7 — Settings and polish:** configurable hotkey, launch at login, editable vocabulary, and engine selection.
- [ ] **P8 — Distribution:** signed/notarized app, installer, and update path.
- [ ] **P9 — Communication coaching:** optional speaking metrics and coaching as a separate later product layer.

## P0 — Transcript recovery

When the focused app has no text field, transcription should still finish and remain available.

- Add **Copy Transcript** to the transcript section.
- Add **Insert Transcript** so the user can focus Terminal or another text field and paste the saved transcript afterward.
- Keep the raw transcript visible after insertion fails.
- Make insertion errors explain that the transcript was saved.
- Preserve the existing clipboard-preservation behavior during insertion.

Acceptance criteria:

- Dictating with Finder focused leaves the transcript available.
- Copy Transcript places the complete raw transcript on the clipboard.
- After focusing a text field, Insert Transcript pastes the saved transcript once.
- The user’s previous clipboard contents are restored after insertion where practical.

## P1 — Recording status overlay

Add a compact, click-through, non-activating overlay on the active display.

- Position: top center, below the menu bar, so it remains visible without covering the Terminal prompt.
- Recording state: microphone icon, animated waveform bars, and “Listening”.
- Transcribing state: subtle spinner and “Transcribing”.
- Success state: brief checkmark, then fade out.
- Failure state: warning icon and “Transcript saved — insertion failed”.
- Never steal keyboard focus from Terminal or the receiving app.
- Support multiple monitors and macOS Reduce Motion.

## ✅ P2 — Default developer vocabulary pack

**What shipped:**
- **222 comprehensive vocabulary terms** across 4 domains:
  - QA and testing (59 terms)
  - QA and developer tools (55 terms)
  - Cloud, databases, and security (48 terms)
  - AI companies, models, and tools (60 terms)
- Integrated into speech recognition engine via `SFSpeechRecognitionRequest.contextualStrings`
- Tests verify all categories, no duplicates, no empty strings, minimum 200+ term coverage

**Note:** Safe correction mappings (play right → Playwright, etc.) are defined for future P2b implementation as a separate transformation layer.

The first three lists are recognition hints. Automatic replacement should be limited to the explicit correction mappings below so ordinary words are not changed unexpectedly.

### QA and testing

```text
quality assurance, QA, SDET, test plan, test case, test suite,
test scenario, test data, test environment, acceptance criteria,
regression testing, smoke testing, sanity testing, exploratory testing,
unit testing, integration testing, end-to-end testing, system testing,
UAT, API testing, contract testing, functional testing,
non-functional testing, performance testing, load testing, stress testing,
soak testing, accessibility testing, security testing, compatibility
testing, cross-browser testing, defect, bug, bug triage, flaky test,
severity, priority, root cause, escalation, stakeholder, sign-off,
assertion, matcher, fixture, mock, stub, spy, test harness, locator,
selector, CSS selector, XPath, page object model, headless browser,
DOM, BDD, Gherkin, Given When Then, Arrange Act Assert
```

### QA and developer tools

```text
Playwright, Selenium, Cypress, Appium, Postman, Newman, Swagger, Jest,
Vitest, pytest, JUnit, TestNG, Cucumber, Allure, BrowserStack,
Sauce Labs,
Git, GitHub, GitLab, Bitbucket, pull request, merge request, commit,
branch, rebase, cherry-pick, CI/CD, GitHub Actions, Jenkins, CircleCI,
Buildkite, Docker, Kubernetes, Helm, Terraform, Ansible, Bash, Zsh,
PowerShell, SSH, tmux, Terminal, iTerm2, VS Code, sprint, backlog,
standup, retro, ticket, release candidate, staging, production,
rollback, hotfix, deployment pipeline
```

### Cloud, databases, and security

```text
AWS, Amazon Web Services, Azure, Google Cloud, GCP, Lambda, EC2, S3,
DynamoDB, CloudFormation, IAM, VPC, EKS, ECS, Cloudflare, Vercel,
Netlify, Nginx, PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch,
Kafka, RabbitMQ, Prometheus, Grafana, Datadog, Sentry, OAuth,
OAuth 2.0, OpenID Connect, OIDC, JWT, SAML, SSO, MFA, Zero Trust,
TLS, SSL, secrets manager, container, microservice, webhook, latency,
throughput, uptime, SLA
```

### AI companies, models, and tools

Model names change frequently. Keep versioned model entries updateable and verify current names when this pack is revised.

```text
OpenAI, ChatGPT, GPT, GPT-5, GPT-5.1, Codex, GPT-5.1-Codex, Whisper,
Anthropic, Claude, Claude Code, Claude Opus, Claude Sonnet, Claude Haiku,
Google DeepMind, Gemini, Gemini Pro, Gemini Flash, Gemma, Vertex AI,
Meta AI, Llama, Llama 4 Scout, Llama 4 Maverick, Mistral AI,
Mistral Large, Mistral Medium, Mistral Small, Codestral, Devstral,
Magistral, Voxtral, xAI, Grok, DeepSeek, DeepSeek-R1, DeepSeek-V3,
Qwen, Cohere, Command, AI21, Jamba, NVIDIA, NeMo, Nemotron, Parakeet,
Hugging Face, Transformers, vLLM, Ollama, LM Studio, MCP,
Model Context Protocol, RAG, embeddings, vector database,
function calling, tool use, agents, agentic
```

### Safe correction mappings

Apply replacements only at word or phrase boundaries and preserve surrounding punctuation.

```text
play right       -> Playwright
pie test         -> pytest
get hub          -> GitHub
dock her         -> Docker
oh auth          -> OAuth
jay son          -> JSON
yamel            -> YAML
post gres        -> PostgreSQL
cloud flare      -> Cloudflare
dynamo d b       -> DynamoDB
a w s            -> AWS
m p c            -> MCP
```

The raw transcript must remain unchanged for debugging and history. Corrections apply only to the text prepared for insertion.

## P3 — Recent transcript history

- Retain the last 10–20 transcripts.
- Allow copy, reinsert, delete, and clear actions.
- Define a retention setting for transcript text and temporary audio.

## P4 — Terminal-aware formatting

- Improve recognition of shell paths, flags, package names, URLs, and code identifiers.
- Support spoken punctuation and “new line” where reliable.
- Avoid transformations that could silently change a shell command.

## P5/P6 — Speech-engine evaluation

Use the same representative recordings for Apple Speech, local Whisper, and Parakeet. Compare:

- transcription accuracy for QA and developer vocabulary;
- end-to-end latency;
- CPU, memory, and battery use;
- offline operation and privacy;
- model size and macOS packaging complexity.

Keep Apple Speech as the default unless another engine wins on the measurements that matter for this app.

## P7/P8/P9 — Polish, distribution, and coaching

- Add configurable hotkey, launch-at-login, editable vocabulary, and engine selection.
- Prepare signing, notarization, installation, and updates before wider distribution.
- Treat communication metrics and coaching as optional future work after the dictation workflow is dependable.
