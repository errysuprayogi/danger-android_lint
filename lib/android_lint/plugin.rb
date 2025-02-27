module Danger

  # Lint files of a gradle based Android project.
  # This is done using the Android's [Lint](https://developer.android.com/studio/write/lint.html) tool.
  # Results are passed out as tables in markdown.
  #
  # @example Running AndroidLint with its basic configuration
  #
  #          android_lint.lint
  #
  # @example Running AndroidLint with a specific gradle task
  #
  #          android_lint.gradle_task = "lintMyFlavorDebug"
  #          android_lint.lint
  #
  # @example Running AndroidLint without running a Gradle task
  #
  #          android_lint.skip_gradle_task = true
  #          android_lint.lint
  #
  # @example Running AndroidLint for a specific severity level and up
  #
  #          # options are ["Warning", "Error", "Fatal"]
  #          android_lint.severity = "Error"
  #          android_lint.lint
  #
  # @see loadsmart/danger-android_lint
  # @tags android, lint
  #
  class DangerAndroidLint < Plugin

    SEVERITY_LEVELS = ["Warning", "Error", "Fatal"]

    # Location of lint report file
    # If your Android lint task outputs to a different location, you can specify it here.
    # Defaults to "app/build/reports/lint/lint-result.xml".
    # @return [String]
    attr_accessor :report_file

    # A getter for `report_file`.
    # @return [String]
    def report_file
      return @report_file || 'app/build/reports/lint/lint-result.xml'
    end

    # Custom gradle task to run.
    # This is useful when your project has different flavors.
    # Defaults to "lint".
    # @return [String]
    attr_accessor :gradle_task

    # A getter for `gradle_task`, returning "lint" if value is nil.
    # @return [String]
    def gradle_task
      @gradle_task ||= "lint"
    end

    # Skip Gradle task.
    # This is useful when Gradle task has been already executed.
    # Defaults to `false`.
    # @return [Bool]
    attr_writer :skip_gradle_task

    # A getter for `skip_gradle_task`, returning `false` if value is nil.
    # @return [Boolean]
    def skip_gradle_task
      @skip_gradle_task ||= false
    end

    # Defines the severity level of the execution.
    # Selected levels are the chosen one and up.
    # Possible values are "Warning", "Error" or "Fatal".
    # Defaults to "Warning".
    # @return [String]
    attr_writer :severity

    # A getter for `severity`, returning "Warning" if value is nil.
    # @return [String]
    def severity
      @severity || SEVERITY_LEVELS.first
    end

    # Enable filtering
    # Only show messages within changed files.
    attr_accessor :filtering

    # Only show messages for the modified lines.
    attr_accessor :filtering_lines

    # Only show messages for issues not in this list.
    attr_accessor :excluding_issue_ids

    # Add correction file and put suggestion on inline file change
    attr_accessor :correction_file

    def correction_file
      return @correction_file || 'lint-correction.json'
    end

    # Calls lint task of your gradle project.
    # It fails if `gradlew` cannot be found inside current directory.
    # It fails if `severity` level is not a valid option.
    # It fails if `xmlReport` configuration is not set to `true` in your `build.gradle` file.
    # @return [void]
    #
    def lint(inline_mode: false)
      unless skip_gradle_task
        return fail("Could not find `gradlew` inside current directory") unless gradlew_exists?
      end

      unless SEVERITY_LEVELS.include?(severity)
        fail("'#{severity}' is not a valid value for `severity` parameter.")
        return
      end

      unless skip_gradle_task
        system "./gradlew #{gradle_task}"
      end

      unless File.exists?(report_file)
        fail("Lint report not found at `#{report_file}`. "\
          "Have you forgot to add `xmlReport true` to your `build.gradle` file?")
      end

      issues = read_issues_from_report
      filtered_issues = filter_issues_by_severity(issues)
      message = ""

      if inline_mode
        # Report with inline comment
        send_inline_comment(filtered_issues)
      else
        message = message_for_issues(filtered_issues)
        markdown("### AndroidLint found issues\n\n" + message) unless message.to_s.empty?
      end

      message
    end

    private

    def read_correction_file
      if File.exists?(correction_file)
        File.open(correction_file) do |f|
          JSON.load(f)
        end
      end
    end

    def read_issues_from_report
      file = File.open(report_file)

      require 'oga'
      report = Oga.parse_xml(file)

      report.xpath('//issue')
    end

    def filter_issues_by_severity(issues)
      issues.select do |issue|
        severity_index(issue.get("severity")) >= severity_index(severity)
      end
    end

    def severity_index(severity)
      SEVERITY_LEVELS.index(severity) || 0
    end

    def message_for_issues(issues)
      message = ""

      SEVERITY_LEVELS.reverse.each do |level|
        filtered = issues.select { |issue| issue.get("severity") == level }
        message << parse_results(filtered, level) unless filtered.empty?
      end

      message
    end

    def parse_results(results, heading)
      target_files = (git.modified_files - git.deleted_files) + git.added_files
      dir = "#{Dir.pwd}/"
      count = 0;
      message = ""

      results.each do |r|
        issue_id = r.get('id')
        next if excluding_issue_ids && excluding_issue_ids.include?(issue_id)
        location = r.xpath('location').first
        filename = location.get('file').gsub(dir, "")
        next unless (!filtering && !filtering_lines) || (target_files.include? filename)
        line = location.get('line').to_i || 'N/A'
        reason = r.get('message')
        if filtering_lines
          added_lines = parse_added_line_numbers(git.diff[filename].patch)
          next unless added_lines.keys.include? line
        end
        count = count + 1
        message << "`#{filename}` | #{line} | #{reason} \n"
      end
      if count != 0
        header = "#### #{heading} (#{count})\n\n"
        header << "| File | Line | Reason |\n"
        header << "| ---- | ---- | ------ |\n"
        message = header + message
      end

      message
    end

    # Send inline comment with danger's warn or fail method
    #
    # @return [void]
    def send_inline_comment(issues)
      target_files = (git.modified_files - git.deleted_files) + git.added_files
      dir = "#{Dir.pwd}/"
      correction = read_correction_file
      SEVERITY_LEVELS.reverse.each do |level|
        filtered = issues.select { |issue| issue.get("severity") == level }
        next if filtered.empty?
        filtered.each do |r|
          location = r.xpath('location').first
          filename = location.get('file').gsub(dir, "")
          id = r.get("id")
          next unless (!filtering && !filtering_lines) || (target_files.include? filename)
          line = (location.get('line') || "0").to_i
          if filtering_lines
            added_lines = parse_added_line_numbers(git.diff[filename].patch)
            next unless added_lines.keys.include? line
          end
          comment = nil
          unless correction.nil?
            correction.each do |result|
              next unless id == result['issue_id'] and added_lines.keys.include? line
              next unless File.extname(filename).eql?(result["ext"])
              next unless check_required_import(filename, id)
              comment = "#{added_lines.fetch(line).gsub(result["target_error"], result["correction"])}"
            end
          end
          send(level === "Warning" ? "warn" : "fail", r.get('message'), file: filename, line: line, comment: comment)
        end
      end
    end

    def check_required_import(filename, id)
      file_path = "#{Dir.pwd}/#{filename}"
      required_import = read_correction_file.select { |res| res["issue_id"] == id }.first["required_import"]
      import_exist = false
      if required_import
        File.readlines(file_path).each do |line|
          next if import_exist
          import_exist = line.strip.eql? required_import
        end
      else
        import_exist = true
      end
      import_exist
    end

    # Parses git diff of a file and retuns an array of added line numbers.
    def parse_added_line_numbers(diff)
      current_line_number = nil
      added_line = Hash.new
      diff_lines = diff.strip.split("\n")
      diff_lines.each_with_index do |line, index|
        if m = /\+(\d+)(?:,\d+)? @@/.match(line)
          # (e.g. @@ -32,10 +32,7 @@)
          current_line_number = Integer(m[1], 10)
        else
          if !current_line_number.nil?
            if line.start_with?('+')
              # added line
              added_line[current_line_number] = line[1..line.length]
              current_line_number += 1
            elsif !line.start_with?('-')
              # unmodified line
              current_line_number += 1
            end
          end
        end
      end
      added_line
    end

    def gradlew_exists?
      `ls gradlew`.strip.empty? == false
    end
  end
end
