# Copyright (C) 2014-2018  Kouhei Sutou <kou@clear-code.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class FileDiffTest < Test::Unit::TestCase
  sub_test_case("parse_header") do
    def parse_header(header_line)
      lines = [header_line]
      file_diff = GitCommitMailer::FileDiff.allocate
      file_diff.send(:parse_header, lines)
      [
        file_diff.instance_variable_get(:@from_file),
        file_diff.instance_variable_get(:@to_file),
      ]
    end

    def test_no_space
      assert_equal([
                     "hello.txt",
                     "hello.txt",
                   ],
                   parse_header("diff --git a/hello.txt b/hello.txt"))
    end

    def test_have_space
      assert_equal([
                     "hello world.txt",
                     "hello world.txt",
                   ],
                   parse_header("diff --git a/hello world.txt b/hello world.txt"))
    end
  end

  sub_test_case("parse_extended_header") do
    sub_test_case("parse_mode_change") do
      def parse_mode_change(line)
        file_diff = GitCommitMailer::FileDiff.allocate
        file_diff.send(:parse_mode_change, line)
        [
          file_diff.instance_variable_get(:@is_mode_changed),
          file_diff.instance_variable_get(:@old_mode),
          file_diff.instance_variable_get(:@new_mode),
        ]
      end

      sub_test_case("mode") do
        def test_one_parent
          assert_equal([
                       true,
                         "000000",
                         "100644",
                       ],
                       parse_mode_change("mode 100644,000000..100644"))
        end

        def test_parents
          assert_equal([
                       true,
                         "000000,100755",
                         "100644",
                       ],
                       parse_mode_change("mode 100644,000000,100755..100644"))
        end
      end
    end
  end
end
