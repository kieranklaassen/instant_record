require "json"

module InstantRecord
  # What both sides' edits of one collection come to.
  module ColumnUnion
    class << self
      # 3-way collection union for `sync_merge :col, :union`:
      #   - Arrays (native Postgres arrays, JSON/serialized arrays)
      #   - JSON-encoded array strings (e.g. '["a","b"]' in SQLite text columns)
      #   - Hashes / JSON objects (3-way key merge; LWW on colliding keys)
      #   - Comma-separated strings (e.g. "bug, urgent")
      def merge(base_val, server_val, client_val, incoming_wins:)
        if server_val.is_a?(Array) || client_val.is_a?(Array)
          return merge_arrays(base_val.is_a?(Array) ? base_val : [], Array(server_val), Array(client_val))
        end

        if server_val.is_a?(Hash) || client_val.is_a?(Hash)
          return merge_hashes(
            base_val.is_a?(Hash) ? base_val : nil,
            server_val.is_a?(Hash) ? server_val : {},
            client_val.is_a?(Hash) ? client_val : {},
            incoming_wins: incoming_wins
          )
        end

        if json_string?(server_val, Array) || json_string?(client_val, Array)
          s_arr = parse_json(server_val, Array) || []
          c_arr = parse_json(client_val, Array) || []
          b_arr = parse_json(base_val, Array) || []
          return JSON.generate(merge_arrays(b_arr, s_arr, c_arr))
        end

        if json_string?(server_val, Hash) || json_string?(client_val, Hash)
          s_hash = parse_json(server_val, Hash) || {}
          c_hash = parse_json(client_val, Hash) || {}
          b_hash = parse_json(base_val, Hash)
          return JSON.generate(merge_hashes(b_hash, s_hash, c_hash, incoming_wins: incoming_wins))
        end

        separator = server_val.to_s.include?(", ") || client_val.to_s.include?(", ") ? ", " : ","
        merged = merge_arrays(split_csv(base_val), split_csv(server_val), split_csv(client_val))
        merged.join(separator)
      end

      private

      # An unknown base is an empty one: nothing can have been removed from it.
      def merge_arrays(base_arr, server_arr, client_arr)
        client_added = client_arr - base_arr
        client_removed = base_arr - client_arr
        (server_arr - client_removed) | client_added
      end

      def merge_hashes(base_hash, server_hash, client_hash, incoming_wins:)
        merged = server_hash.dup
        if base_hash.nil?
          client_hash.each do |k, v|
            merged[k] = v if !merged.key?(k) || incoming_wins
          end
        else
          (base_hash.keys | client_hash.keys).each do |k|
            c_present = client_hash.key?(k)
            b_present = base_hash.key?(k)
            next if c_present == b_present && client_hash[k] == base_hash[k]

            s_changed = server_hash.key?(k) != b_present || server_hash[k] != base_hash[k]
            if !s_changed || incoming_wins
              c_present ? merged[k] = client_hash[k] : merged.delete(k)
            end
          end
        end
        merged
      end

      # A string that spells out a JSON Array or Hash.
      def json_string?(value, type)
        opening = type == Array ? "[" : "{"
        value.is_a?(String) && value.lstrip.start_with?(opening) && !parse_json(value, type).nil?
      end

      # The Array or Hash that `value` is or spells out in JSON, else nil.
      def parse_json(value, type)
        return nil if value.nil? || value == ""
        return value if value.is_a?(type)

        parsed = JSON.parse(value.to_s)
        parsed if parsed.is_a?(type)
      rescue JSON::ParserError
        nil
      end

      def split_csv(value)
        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
