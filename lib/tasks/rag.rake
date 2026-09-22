# frozen_string_literal: true

namespace :rag do
  desc "Tworzy indeks Redis (idempotentne)"
  task create_index: :environment do
    Rag::Index.create!
    puts Rag.redis.call("FT._LIST").inspect
  end

  desc "Indeksuje zmienione pliki docs/user/**/*.md (pomija niezmienione)"
  task index: :environment do
    Rag::Indexer.call(root: Rails.root)
  end

  desc "Usuwa indeks i buduje od zera (wymagane po zmianie modelu, DIM lub schematu)"
  task reindex: :environment do
    Rag::Index.drop!
    Rag::Indexer.call(root: Rails.root, force: true)
  end

  desc "Sprawdza Redis i model embeddingów; mierzy czas embeddingu pytania"
  task doctor: :environment do
    puts "Redis FT._LIST: #{Rag.redis.call('FT._LIST').inspect}"

    2.times do |i|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      vector = Rag::Embedder.call(["Jak wystawić fakturę korygującą?"]).first
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts format("Embedding %s, przebieg %d%s: wymiar %d (oczekiwano %d), %.2f s",
                  Rag::Embedder::MODEL, i + 1, i.zero? ? " (może zawierać ładowanie modelu)" : "",
                  vector.size, Rag::Index::DIM, elapsed)
    end

    if Rag::Index.exists?
      info = Rag.redis.call("FT.INFO", Rag::Index::NAME).each_slice(2).to_h
      puts "Indeks #{Rag::Index::NAME}: num_docs=#{info['num_docs']}"
    else
      puts "Indeks #{Rag::Index::NAME} nie istnieje - uruchom rag:index"
    end

    if Rag::Answer.enabled?(env: Rails.env)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Rag::Answer.default_client.generate(
        model: Rag::Answer::MODEL, system_instruction: "Odpowiadaj po polsku.",
        user_text: "Odpowiedz jednym słowem: działa", max_output_tokens: Rag::Answer::MAX_OUTPUT_TOKENS,
        thinking_level: Rag::Answer::THINKING_LEVEL
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts format("Gemini %s: %s (%.2f s, finish_reason=%s, usage=%s)",
                  Rag::Answer::MODEL, response.text.strip.inspect, elapsed, response.finish_reason, response.usage)
    elsif Rag::Answer.api_key.empty?
      puts "Gemini: wyłączone (brak RAG_GEMINI_API_KEY)"
    else
      puts "Gemini: wyłączone poza development (RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT=1 tylko na płatnym kluczu)"
    end
  end

  desc 'Wyszukiwanie + odpowiedź Gemini z konsoli: bin/rails rag:ask Q="pytanie"'
  task ask: :environment do
    question = ENV["Q"].to_s.strip
    abort 'Użycie: bin/rails rag:ask Q="pytanie"' if question.empty?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    search = Rag::Search.call(question)
    search_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    answer = Rag::Answer.call(question, env: Rails.env, search_result: search, logger: Logger.new($stdout))
    total_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    puts "Status: #{answer.status}"
    puts answer.text if answer.text
    answer.sources.each_with_index { |s, i| puts format("[%d] %.4f %s (%s)", i + 1, s[:distance], s[:heading], s[:source]) }
    issues = Rag::Answer.citation_issues(answer.text, answer.sources.size) if answer.text
    puts "Uwagi: #{issues.join('; ')}" if issues&.any?
    puts format("Czas: wyszukiwanie %.2f s, razem %.2f s | finish_reason=%s | usage=%s",
                search_time, total_time, answer.finish_reason, answer.usage)
  end

  desc "Odpowiedzi Gemini dla pytań z golden.yml -> tmp/rag_answers_*.md (do ręcznej oceny)"
  task eval_answers: :environment do
    abort "Gemini wyłączone (brak klucza lub środowisko inne niż development)" unless Rag::Answer.enabled?(env: Rails.env)

    delay = Float(ENV.fetch("RAG_GEMINI_DELAY_SECONDS", "6")) # dopasuj do swojego limitu RPM z AI Studio
    cases = YAML.safe_load_file(Rails.root.join("spec/rag/golden.yml"))
    path = Rails.root.join("tmp", "rag_answers_#{Time.now.strftime('%Y%m%d_%H%M%S')}.md")
    calls = 0
    counts = Hash.new(0)

    File.open(path, "w") do |out|
      out.puts "# Odpowiedzi Gemini (#{Rag::Answer::MODEL}), #{Time.now}\n"
      out.puts "Ocena ręczna dla każdego pytania: poprawna / częściowo / błędna / zmyślona treść.\n"

      cases.each_with_index do |c, i|
        search = Rag::Search.call(c["question"])
        sleep(delay) if search.found? && calls.positive?
        answer = Rag::Answer.call(c["question"], env: Rails.env, search_result: search, logger: Logger.new($stdout))
        calls += 1 if search.found?
        counts[answer.status] += 1

        out.puts "\n## #{i + 1}. #{c['question']}\n"
        out.puts "- Oczekiwane źródła: #{Array(c['expected_sources']).join(', ').then { |v| v.empty? ? '(spoza zakresu)' : v }}"
        out.puts "- Status: #{answer.status}, finish_reason: #{answer.finish_reason}"
        answer.sources.each_with_index { |s, n| out.puts "- [#{n + 1}] #{s[:source]} (#{s[:heading]})" }
        if answer.text
          issues = Rag::Answer.citation_issues(answer.text, answer.sources.size)
          out.puts "- Automatyczne uwagi: #{issues.empty? ? 'brak' : issues.join('; ')}"
          out.puts "\n#{answer.text}\n"
        end
        out.puts "\nOcena: ____\n"
        puts "#{i + 1}/#{cases.size} #{answer.status}"

        if answer.status == :rate_limited
          puts "Limit Gemini wyczerpany - przerwano. Dzienny limit odnawia się o północy czasu pacyficznego."
          break
        end
      end
    end

    puts "Statusy: #{counts}"
    puts "Zapisano: #{path}"
  end

  desc 'Wyszukiwanie z konsoli: bin/rails rag:search Q="pytanie"'
  task search: :environment do
    question = ENV["Q"].to_s.strip
    abort 'Użycie: bin/rails rag:search Q="pytanie"' if question.empty?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Rag::Search.call(question)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    if result.found?
      result.results.each_with_index do |r, i|
        puts format("%d. %.4f  %s  (%s)", i + 1, r[:distance], r[:heading], r[:source])
      end
    else
      puts "Brak wyników poniżej progu #{Rag::Search::MAX_DISTANCE}. Najbliższe tematy:"
      result.suggestions.each { |s| puts format("   %.4f  %s  (%s)", s[:distance], s[:title], s[:source]) }
    end
    puts format("Czas: %.2f s", elapsed)
  end

  desc "Ewaluacja: Recall@RESULTS i MRR na poziomie plików, dystanse do kalibracji progu (spec/rag/golden.yml)"
  task eval: :environment do
    candidates = Integer(ENV.fetch("K", Rag::Search::CANDIDATES.to_s))
    cutoff = Rag::Search::RESULTS
    cases = YAML.safe_load_file(Rails.root.join("spec/rag/golden.yml"))
    recalls = []
    reciprocal_ranks = []
    in_scope_distances = []
    out_of_scope_distances = []

    cases.each do |c|
      expected = Array(c["expected_sources"])
      ranked = Rag::Retriever.call(c["question"], k: candidates).uniq { |r| r[:source] }
      top = ranked.first
      line = format("%-60s top=%.4f %s", c["question"][0, 60], top ? top[:distance] : -1, top&.dig(:source))

      if expected.empty?
        out_of_scope_distances << top[:distance] if top
        puts "#{line}  [SPOZA ZAKRESU]"
        next
      end

      in_scope_distances << top[:distance] if top
      got = ranked.first(cutoff).map { |r| r[:source] }
      recalls << (expected & got).size.fdiv(expected.size)
      rank = got.index { |s| expected.include?(s) }
      reciprocal_ranks << (rank ? 1.0 / (rank + 1) : 0.0)
      puts "#{line}  #{rank ? "trafienie ##{rank + 1}" : 'PUDŁO'}"
    end

    abort "Brak pytań z expected_sources w golden.yml" if recalls.empty?
    puts "Recall@#{cutoff} (pliki): #{(recalls.sum / recalls.size).round(3)}"
    puts "MRR: #{(reciprocal_ranks.sum / reciprocal_ranks.size).round(3)}"
    puts "Dystans top, pytania w zakresie:  min=#{in_scope_distances.min&.round(4)} max=#{in_scope_distances.max&.round(4)}"
    unless out_of_scope_distances.empty?
      puts "Dystans top, pytania spoza zakresu: min=#{out_of_scope_distances.min.round(4)} max=#{out_of_scope_distances.max.round(4)}"
    end
    puts "Obecny próg RAG_MAX_DISTANCE: #{Rag::Search::MAX_DISTANCE}"
  end
end
