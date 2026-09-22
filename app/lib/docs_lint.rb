# frozen_string_literal: true

require "date"
require "pathname"
require "set"
require "yaml"

# Sprawdza zgodność dokumentacji użytkownika z kodem aplikacji.
#
# Konwencje, które lint egzekwuje:
# - **pogrubienie** oznacza WYŁĄCZNIE dosłowną etykietę interfejsu (przycisk, menu, pole, komunikat)
#   i musi istnieć jako wartość w config/locales/**/*.yml dla danego języka;
# - front matter zawiera: title, audience, verified_by (ścieżki testów), last_verified (data);
# - opcjonalne questions: lista przykładowych pytań użytkowników (dołączana do wektora, nie wyświetlana);
# - brak odwołań do innych miejsc tekstu ("jak wyżej" itp.), bo fragmenty są wyszukiwane osobno.
class DocsLint
  REQUIRED_KEYS = %w[title audience verified_by last_verified].freeze
  RELATIVE_PHRASES = ["jak wyżej", "powyżej", "poniżej", "wyżej opisan", "opisane wcześniej", "patrz wyżej"].freeze
  BOLD = /\*\*(.+?)\*\*/

  Issue = Struct.new(:level, :location, :message, keyword_init: true) do
    def to_s
      "#{level.upcase} #{location}: #{message}"
    end
  end

  def self.call(root:, docs_glob: "docs/user/**/*.md", locale: "pl")
    new(Pathname(root), docs_glob, locale).call
  end

  def initialize(root, docs_glob, locale)
    @root = root
    @docs_glob = docs_glob
    @locale = locale
  end

  def call
    labels, patterns = load_locale_values
    issues = []

    doc_paths.each do |path|
      relative = path.relative_path_from(@root).to_s
      content = File.read(path, encoding: "UTF-8").gsub("\r\n", "\n")
      front_matter, body_offset = parse_front_matter(content)

      issues.concat(check_front_matter(relative, front_matter))
      issues.concat(check_body(relative, content.lines, body_offset, labels, patterns))
    rescue Psych::SyntaxError => e
      issues << Issue.new(level: "error", location: relative, message: "błędny YAML front matter: #{e.message}")
    end

    issues
  end

  private

  def doc_paths
    Dir.glob(@root.join(@docs_glob).to_s)
       .reject { |p| File.basename(p).start_with?("_") }
       .sort
       .map { |p| Pathname(p) }
  end

  def load_locale_values
    values = []
    Dir.glob(@root.join("config/locales/**/*.yml").to_s).sort.each do |file|
      data = YAML.safe_load_file(file, aliases: true) || {}
      collect_strings(data[@locale], values) if data.is_a?(Hash)
    end

    exact = values.map(&:strip).to_set
    patterns = values.select { |v| v.include?("%{") }.map do |v|
      Regexp.new("\\A#{Regexp.escape(v.strip).gsub(/%\\\{\w+\\\}/, '.+')}\\z")
    end
    [exact, patterns]
  end

  def collect_strings(node, out)
    case node
    when Hash then node.each_value { |v| collect_strings(v, out) }
    when Array then node.each { |v| collect_strings(v, out) }
    when String then out << node
    end
  end

  # Zwraca [hash, numer_linii_pierwszej_po_front_matter (0-based)]
  def parse_front_matter(content)
    return [{}, 0] unless content.start_with?("---\n")

    closing = content.index("\n---\n", 4)
    return [{}, 0] unless closing

    data = YAML.safe_load(content[4...closing], permitted_classes: [Date]) || {}
    [data, content[0..(closing + 4)].count("\n")]
  end

  def check_front_matter(relative, fm)
    issues = []

    REQUIRED_KEYS.each do |key|
      next unless fm[key].nil? || fm[key].to_s.strip.empty?

      issues << Issue.new(level: "error", location: relative, message: "brak pola front matter: #{key}")
    end

    Array(fm["verified_by"]).each do |test_path|
      next if @root.join(test_path).file?

      issues << Issue.new(level: "error", location: relative, message: "verified_by wskazuje nieistniejący plik: #{test_path}")
    end

    if fm.key?("questions") && !(fm["questions"].is_a?(Array) && fm["questions"].all? { |q| q.is_a?(String) && !q.strip.empty? })
      issues << Issue.new(level: "error", location: relative, message: "questions musi być listą niepustych tekstów")
    end

    if fm.key?("last_verified") && !fm["last_verified"].is_a?(Date)
      issues << Issue.new(level: "error", location: relative, message: "last_verified musi być datą RRRR-MM-DD")
    end

    issues
  end

  def check_body(relative, lines, offset, labels, patterns)
    issues = []
    in_fence = false

    lines.each_with_index do |line, index|
      next if index < offset

      if line.start_with?("```", "~~~")
        in_fence = !in_fence
        next
      end
      next if in_fence

      location = "#{relative}:#{index + 1}"

      line.scan(BOLD).flatten.each do |label|
        label = label.strip
        next if labels.include?(label) || patterns.any? { |re| re.match?(label) }

        issues << Issue.new(level: "error", location: location,
                            message: "etykieta **#{label}** nie występuje w config/locales (#{@locale})")
      end

      lowered = line.downcase
      RELATIVE_PHRASES.each do |phrase|
        next unless lowered.include?(phrase)

        issues << Issue.new(level: "warning", location: location,
                            message: "odwołanie \"#{phrase}\" - fragment będzie czytany bez reszty dokumentu")
      end
    end

    issues
  end
end
