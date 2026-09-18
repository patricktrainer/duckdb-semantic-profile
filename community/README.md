# Community extension submission

`description.yml` is the descriptor for
[duckdb/community-extensions](https://github.com/duckdb/community-extensions).
It lives here for reference; submitting means copying it into that repo.

```bash
gh repo fork duckdb/community-extensions --clone
cd community-extensions
mkdir -p extensions/semantic_profile
cp /path/to/duckdb-semantic-profile/community/description.yml extensions/semantic_profile/
git checkout -b add-semantic-profile
git add extensions/semantic_profile/description.yml
git commit -m "Add semantic_profile extension"
gh pr create --repo duckdb/community-extensions
```

Once merged, users install with:

```sql
INSTALL semantic_profile FROM community;
LOAD semantic_profile;
```

## Keeping it current

`repo.ref` pins a commit — currently the `v0.1.0` tag. Their CI builds exactly
that tree, so a new release means a new PR bumping `version` and `ref`.

`excluded_platforms` matches what this repo's own CI builds. Widen it only after
verifying the platform actually works.
