# HerNess legal translation import

The importer reads the current Turkish and English source bodies from the
legacy public record, then requires reviewed Markdown files for every other
locale before it performs any remote write.

For version `2026-08-26`, add these files for each locale below:

```text
<locale>/terms.md
<locale>/privacy-notice.md
```

Required locale directories are the 30 entries in
`mobile/localization/languages.json`. Keep Markdown headings, links, and
placeholders intact. The importer stores the 28 additional locales as
`translation_status = 'draft'`; only the Turkish master is binding and the
English source is published as the existing read-only source. A legal owner
must review a draft before promoting it to `approved` or `published`.

Run a dry validation first:

```sh
node cloudflare/scripts/seed-legal-documents.mjs --drafts-dir=/absolute/path/to/this-directory
```

Only after the 60 files have been reviewed and the Wrangler alias has been
verified should the remote flag be used:

```sh
node cloudflare/scripts/seed-legal-documents.mjs --remote --drafts-dir=/absolute/path/to/this-directory
```

After the import, run the read-only D1/R2 integrity check. It expects exactly
60 D1 rows and downloads all 60 R2 objects into a temporary directory before
comparing their SHA-256 values; the temporary files and directory are removed
when the check finishes:

```sh
node cloudflare/scripts/readback-legal-documents.mjs
```
