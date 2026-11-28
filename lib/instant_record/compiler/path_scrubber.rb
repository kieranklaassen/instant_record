require_relative "runner"

module InstantRecord
  class Compiler
    # Replaces a build machine's absolute path prefix inside a compiled Wasm
    # binary with a neutral prefix of identical byte length so data-segment
    # offsets stay intact.
    module PathScrubber
      CHUNK_SIZE = 524_288
      DENSE_WRITE_THRESHOLD = 32
      WINDOW_GAP_COALESCE = 32_768
      EXACT_OVERLAP_MAX_LEN = 1_024
      NEUTRAL_HEAD = "/build".b.freeze
      NEUTRAL_PAD = "/_".b.freeze

      module_function

      def scrub(path, prefix)
        prefix_bytes = prefix.to_s.b
        raise ArgumentError, "prefix must not be empty" if prefix_bytes.empty?

        prefix_len = prefix_bytes.bytesize
        neutral = build_neutral(prefix_len)
        raise BuildError, "neutral prefix length mismatch" unless neutral.bytesize == prefix_len

        same_bytes = (prefix_bytes == neutral)
        deltas = same_bytes ? nil : overlap_window_deltas(prefix_bytes, neutral)
        track_windows = !same_bytes && !deltas.nil?
        delta_start = deltas ? deltas[0] : 0
        delta_end = deltas ? deltas[1] : 0

        File.open(path, "r+b") do |io|
          initial_size = io.size
          return { count: 0, remaining: 0, size: initial_size } if initial_size < prefix_len

          read_size = CHUNK_SIZE >= prefix_len ? CHUNK_SIZE : prefix_len
          overlap = prefix_len - 1
          read_buf = String.new(capacity: read_size, encoding: Encoding::BINARY)
          seam_buf = overlap > 0 ? String.new(capacity: overlap * 2, encoding: Encoding::BINARY) : nil
          write_buf = nil

          count = 0
          file_offset = 0
          tail_len = 0
          chunk_matches = []
          windows = track_windows ? [] : nil

          while (chunk = io.read(read_size, read_buf))
            chunk_len = chunk.bytesize
            break if chunk_len == 0

            scan_pos = 0
            seam_scan_pos = 0
            if tail_len > 0
              seam_head = chunk_len < overlap ? chunk_len : overlap
              seam_buf.bytesplice(tail_len, 0, chunk, 0, seam_head)
              idx = seam_buf.byteindex(prefix_bytes)
              if idx && idx < tail_len
                match_off = file_offset - tail_len + idx
                count += 1
                pwrite_all(io, neutral, match_off) unless same_bytes
                push_window(windows, match_off + delta_start, match_off + delta_end) if track_windows
                scan_pos = idx + prefix_len - tail_len
                seam_scan_pos = scan_pos
              end
            end

            if same_bytes
              while (idx = chunk.byteindex(prefix_bytes, scan_pos))
                count += 1
                scan_pos = idx + prefix_len
              end
            else
              chunk_matches.clear
              while (idx = chunk.byteindex(prefix_bytes, scan_pos))
                chunk_matches << idx
                scan_pos = idx + prefix_len
              end
            end

            next_file_offset = file_offset + chunk_len
            at_eof = chunk_len < read_size

            # Save trailing overlap bytes via bytesplice (avoids CoW-sharing read_buf)
            # before mutating chunk in place.
            if !at_eof && overlap > 0
              keep_from = chunk_len - overlap
              keep_from = scan_pos if scan_pos > keep_from
              tail_len = chunk_len - keep_from
              if tail_len > 0
                seam_buf.bytesplice(0, seam_buf.bytesize, chunk, keep_from, tail_len)
              else
                seam_buf.clear
              end
            else
              tail_len = 0
            end

            if !same_bytes && !chunk_matches.empty?
              mcount = chunk_matches.length
              count += mcount

              if mcount <= DENSE_WRITE_THRESHOLD
                i = 0
                while i < mcount
                  match_off = file_offset + chunk_matches[i]
                  pwrite_all(io, neutral, match_off)
                  push_window(windows, match_off + delta_start, match_off + delta_end) if track_windows
                  i += 1
                end
              else
                first_idx = chunk_matches[0]
                last_idx = chunk_matches[-1]
                last_end = last_idx + prefix_len
                span_len = last_end - first_idx
                i = 0
                while i < mcount
                  chunk.bytesplice(chunk_matches[i], prefix_len, neutral)
                  i += 1
                end

                if span_len >= chunk_len / 2
                  if seam_scan_pos > 0
                    chunk.bytesplice(0, seam_scan_pos, neutral, prefix_len - seam_scan_pos, seam_scan_pos)
                  end
                  pwrite_all(io, chunk, file_offset)
                else
                  write_buf ||= String.new(capacity: span_len, encoding: Encoding::BINARY)
                  write_buf.bytesplice(0, write_buf.bytesize, chunk, first_idx, span_len)
                  pwrite_all(io, write_buf, file_offset + first_idx)
                  if track_windows && seam_scan_pos > 0
                    chunk.bytesplice(0, seam_scan_pos, neutral, prefix_len - seam_scan_pos, seam_scan_pos)
                  end
                end

                if track_windows
                  first_off = file_offset + first_idx
                  last_off = file_offset + last_idx
                  if chunk.byteindex(prefix_bytes)
                    push_window(windows, first_off + delta_start, last_off + delta_end)
                  else
                    if first_off + delta_start < file_offset
                      push_window(windows, first_off + delta_start, file_offset + overlap)
                    end
                    if !at_eof && last_off + delta_end > next_file_offset
                      ws_right = next_file_offset - overlap
                      min_start = first_off + delta_start
                      ws_right = min_start if min_start > ws_right
                      push_window(windows, ws_right, last_off + delta_end)
                    end
                  end
                end
              end
            end

            file_offset = next_file_offset
            break if at_eof
          end

          if count > 0 && !same_bytes
            raise BuildError, "scrubbed wasm size changed" unless io.size == file_offset
          end

          remaining =
            if count == 0
              0
            elsif same_bytes
              count
            elsif !track_windows || windows.empty?
              0
            else
              count_remaining_in_windows(io, prefix_bytes, windows, file_offset, read_size, read_buf, seam_buf)
            end

          { count: count, remaining: remaining, size: file_offset }
        end
      end

      class << self
        private

        def build_neutral(prefix_len)
          if prefix_len <= NEUTRAL_HEAD.bytesize
            NEUTRAL_HEAD.byteslice(0, prefix_len).b
          else
            pad_repeats = (prefix_len - NEUTRAL_HEAD.bytesize + 1) / NEUTRAL_PAD.bytesize
            (NEUTRAL_HEAD + NEUTRAL_PAD * pad_repeats).byteslice(0, prefix_len).b
          end
        end

        # Returns [delta_start, delta_end) around a replaced offset i where a newly
        # formed occurrence of prefix_bytes could exist after writing neutral, or nil
        # if no boundary overlap between prefix_bytes and neutral is possible.
        def overlap_window_deltas(prefix_bytes, neutral)
          len = prefix_bytes.bytesize
          return nil if len <= 1
          return [-(len - 1), 2 * len - 1] if len > EXACT_OVERLAP_MAX_LEN

          p0 = prefix_bytes.getbyte(0)
          p1 = prefix_bytes.getbyte(1)
          plast = prefix_bytes.getbyte(len - 1)
          n0 = neutral.getbyte(0)
          n1 = neutral.getbyte(1)
          nlast = neutral.getbyte(len - 1)

          left_min_k = nil
          left_max_k = nil
          right_min_k = nil
          right_max_k = nil

          k = 1
          while k < len
            if prefix_bytes.getbyte(len - k) == n0 && plast == neutral.getbyte(k - 1) &&
               (k <= 2 || (prefix_bytes.getbyte(len - k + 1) == n1 &&
                           prefix_bytes.byteslice(len - k, k) == neutral.byteslice(0, k)))
              left_min_k ||= k
              left_max_k = k
            end
            if p0 == neutral.getbyte(len - k) && prefix_bytes.getbyte(k - 1) == nlast &&
               (k <= 2 || (p1 == neutral.getbyte(len - k + 1) &&
                           prefix_bytes.byteslice(0, k) == neutral.byteslice(len - k, k)))
              right_min_k ||= k
              right_max_k = k
            end
            k += 1
          end

          if left_min_k && right_min_k
            [-(len - left_min_k), 2 * len - right_min_k]
          elsif left_min_k
            [-(len - left_min_k), left_max_k]
          elsif right_min_k
            [len - right_max_k, 2 * len - right_min_k]
          end
        end

        def push_window(windows, ws, we)
          ws = 0 if ws < 0
          return if we <= ws

          if !windows.empty? && ws <= windows[-1] + WINDOW_GAP_COALESCE
            windows[-1] = we if we > windows[-1]
            if ws < windows[-2]
              windows[-2] = ws
              while windows.length >= 4 && windows[-2] <= windows[-3] + WINDOW_GAP_COALESCE
                prev_end = windows.pop
                prev_start = windows.pop
                windows[-1] = prev_end if prev_end > windows[-1]
                windows[-2] = prev_start if prev_start < windows[-2]
              end
            end
          else
            windows << ws << we
          end
        end

        def pwrite_all(io, bytes, offset)
          len = bytes.bytesize
          written = io.pwrite(bytes, offset)
          return written if written == len

          total = written
          while total < len
            n = io.pwrite(bytes.byteslice(total, len - total), offset + total)
            raise BuildError, "short write while scrubbing wasm" if n <= 0

            total += n
          end
          total
        end

        def pread_all(io, len, offset, buf)
          data = io.pread(len, offset, buf)
          return data if data.bytesize == len

          out = data.dup
          while out.bytesize < len
            chunk = io.pread(len - out.bytesize, offset + out.bytesize)
            raise BuildError, "unexpected EOF while scrubbing wasm" if chunk.nil? || chunk.empty?

            out << chunk
          end
          out
        rescue EOFError
          raise BuildError, "unexpected EOF while scrubbing wasm"
        end

        def count_remaining_in_windows(io, prefix_bytes, windows, file_size, read_size, read_buf, seam_buf)
          rem = 0
          i = 0
          wlen = windows.length
          while i < wlen
            ws = windows[i]
            we = windows[i + 1]
            we = file_size if we > file_size
            rem += count_occurrences_in_range(io, prefix_bytes, ws, we, read_size, read_buf, seam_buf)
            i += 2
          end
          rem
        end

        def count_occurrences_in_range(io, prefix_bytes, range_start, range_end, read_size, read_buf, seam_buf)
          prefix_len = prefix_bytes.bytesize
          remaining_bytes = range_end - range_start
          return 0 if remaining_bytes < prefix_len

          if remaining_bytes <= read_size
            data = pread_all(io, remaining_bytes, range_start, read_buf)
            count = 0
            pos = 0
            while (idx = data.byteindex(prefix_bytes, pos))
              count += 1
              pos = idx + prefix_len
            end
            return count
          end

          overlap = prefix_len - 1
          count = 0
          pos_file = range_start
          tail_len = 0

          while pos_file < range_end
            to_read = range_end - pos_file
            to_read = read_size if to_read > read_size
            chunk = pread_all(io, to_read, pos_file, read_buf)
            chunk_len = chunk.bytesize
            break if chunk_len == 0

            scan_pos = 0
            if tail_len > 0
              seam_head = chunk_len < overlap ? chunk_len : overlap
              seam_buf.bytesplice(tail_len, 0, chunk, 0, seam_head)
              idx = seam_buf.byteindex(prefix_bytes)
              if idx && idx < tail_len
                count += 1
                scan_pos = idx + prefix_len - tail_len
              end
            end

            while (idx = chunk.byteindex(prefix_bytes, scan_pos))
              count += 1
              scan_pos = idx + prefix_len
            end

            pos_file += chunk_len
            break if pos_file >= range_end

            if overlap > 0
              keep_from = chunk_len - overlap
              keep_from = 0 if keep_from < 0
              keep_from = scan_pos if scan_pos > keep_from
              tail_len = chunk_len - keep_from
              if tail_len > 0
                seam_buf.bytesplice(0, seam_buf.bytesize, chunk, keep_from, tail_len)
              else
                seam_buf.clear
              end
            end
          end

          count
        end
      end
    end
  end
end
