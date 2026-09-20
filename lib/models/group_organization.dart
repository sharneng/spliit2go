/// Device-local, mutually exclusive placement in the group list.
/// Names are persisted in SQLite; keep them stable across releases.
enum GroupOrganization { active, favorite, archived }
