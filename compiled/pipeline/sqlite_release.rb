class Release
  COLUMN = "word_count"
  def self.version = "20260723183002"

  def self.local_columns
    columns = []
    SqliteAdapter.each_row("PRAGMA table_info(notes)") { |row| columns << row["name"].to_s }
    columns
  end

  def self.pending? = !local_columns.include?(COLUMN)

  def self.ship
    return unless pending?
    Note.transaction do
      Db.exec("ALTER TABLE notes ADD COLUMN word_count INTEGER")
      Note.all.each { |note| update_count(note.id, note.body) }
      Db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")
      Db.exec("INSERT INTO schema_migrations (version) VALUES ('20260723183002')")
    end
  end

  def self.roll_back
    return if pending?
    Note.transaction do
      Db.exec("ALTER TABLE notes DROP COLUMN word_count")
      Db.exec("DELETE FROM schema_migrations WHERE version = '20260723183002'")
    end
  end

  def self.update_count(id, body)
    Db.exec("UPDATE notes SET word_count = " + body.to_s.split.size.to_s + " WHERE id = " + Db.escape_string(id.to_s))
  end
  def self.word_count(id)
    count = 0
    SqliteAdapter.each_row("SELECT word_count FROM notes WHERE id = " + Db.escape_string(id.to_s)) { |row| count = row["word_count"].to_s.to_i }
    count
  end

  def self.exec_sql(sql)
    Db.exec(sql)
  end
end
