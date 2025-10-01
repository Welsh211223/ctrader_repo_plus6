# ctrader — Operator's Organizer

## Daily Ops Checklist
- [ ] \git pull\ from \main\
- [ ] Update prices (CoinSpot/Coingecko fetch)
- [ ] Generate rebalance plan (paper)
- [ ] Review risk caps & trend filters
- [ ] Execute (paper or live), then log outcomes
- [ ] Discord notification sent and verified

## Release Flow
1. Branch: \chore/ops-hardening\ or \eat/<name>\
2. Run \pre-commit run --all-files\
3. Bump version in \ctrader/__init__.py\ (if present) and \CHANGELOG.md\
4. Commit (signed), push, open PR → squash & merge.
5. Tag release: \git tag vX.Y.Z && git push --tags\

## Branching
- \main\: stable
- \chore/*\: maintenance, quality, infra
- \eat/*\: new features
- \ix/*\: bugfixes

## Secrets Handling
- Never commit keys. \detect-secrets\ enforces this.
- Keep \.env\ only locally. Use examples in \.env.example\.

## Rollback
- \git revert <SHA>\
- If a deploy breaks, roll back to last tag \git checkout vX.Y.Z\
