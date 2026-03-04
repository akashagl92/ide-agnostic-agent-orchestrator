# Deploy Guide (Independent Public Repo)

## 1. Create repo locally
```bash
cd portable-pai-core
git init
git add .
git commit -m "Initial modular IDE-agnostic framework release"
git branch -M main
```

## 2. Create remote and push
### Option A: GitHub CLI
```bash
gh repo create <org-or-user>/portable-pai-core --public --source=. --remote=origin --push
```

### Option B: Manual remote
```bash
git remote add origin git@github.com:<org-or-user>/portable-pai-core.git
git push -u origin main
```

## 3. Post-publish setup
- Add repository topics: `ai`, `agentic`, `orchestration`, `ide-agnostic`, `policy-engine`.
- Enable branch protection for `main`.
- Require PRs for changes to `core/schemas/*` and `core/scripts/*`.
- Add releases with semantic version tags (`v0.1.0`, `v0.2.0`, ...).

## 4. Validate from fresh clone
```bash
git clone git@github.com:<org-or-user>/portable-pai-core.git
cd portable-pai-core
bash scripts/init-project.sh --project /path/to/target-project
```
