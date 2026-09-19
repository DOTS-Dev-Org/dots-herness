-- Store the immutable license choice on every release. The plugin-level
-- license remains as a backwards-compatible summary for registry consumers.
ALTER TABLE marketplace_releases ADD COLUMN license TEXT NOT NULL DEFAULT '';
UPDATE marketplace_releases
   SET license = (
     SELECT license
       FROM marketplace_plugins
      WHERE marketplace_plugins.id = marketplace_releases.plugin_id
   )
 WHERE license = '';
