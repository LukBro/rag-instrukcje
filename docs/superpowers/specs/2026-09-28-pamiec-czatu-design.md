# Pamięć czatu: pytania doprecyzowujące w /api/ask

Zgłoszenie: [BRO-72](https://linear.app/browarek/issue/BRO-72/pamiec-czatu-pytania-doprecyzowujace-w-apiask)
Data: 2026-09-28

## Problem

Każde pytanie do `POST /api/ask` jest dziś niezależne. Pytanie doprecyzowujące w rodzaju
„a jak to usunąć?” nie zawiera tematu, więc embedding nie ma czego dopasować i żądanie kończy się
statusem `no_results`. Użytkownik musi za każdym razem powtarzać pełny kontekst.

## Czego ten projekt nie robi

Nie dotyka `Answer::SYSTEM_PROMPT`. Prompt został skalibrowany w BRO-27 (fałszywe odmowy, łączenie
kroków z kilku instrukcji) i jest głównym ryzykiem regresji jakości odpowiedzi. Projekt jest tak
ułożony, żeby do `Answer` trafiało pytanie **samodzielne** — takie, jakiego prompt oczekuje dziś.

Poza zakresem: trzymanie stanu rozmowy na serwerze, streaming odpowiedzi, cache odpowiedzi.

## Kontrakt

```
POST /api/ask
{
  "question": "a jak to usunąć?",
  "history": ["jak dodać adres dostawy klienta?"]
}
```

- `history` jest **opcjonalne**: tablica poprzednich **pytań użytkownika**, najstarsze pierwsze.
  Brak pola albo pusta tablica = zachowanie identyczne jak dziś, więc obecny klient nie wymaga
  żadnej zmiany.
- Odpowiedzi asystenta do historii nie wchodzą. Kosztują setki tokenów na turę, a do ustalenia
  tematu pytania wystarczają same pytania.
- Limity: **5 ostatnich pytań**, każde do **500 znaków**. Nadwyżka jest obcinana po cichu, bez
  błędu 400 — klient nie powinien wywracać się na długości historii.
- Format odpowiedzi **bez zmian**: `status`, `answer`, `finish_reason`, `sources`, `suggestions`.

Stan rozmowy trzyma klient. Serwer pozostaje bezstanowy: nic nie przechowuje, nie ma TTL ani cyklu
życia sesji, nie powstaje pytanie o przechowywanie treści rozmów.

## Przebieg żądania

1. Niepusta `history` → `Rag::QuestionRewriter` ustala samodzielne pytanie. Dla pytania, które już
   jest samodzielne, zwraca `nil` i nic się nie zmienia.
2. `Search.call(pytanie przepisane albo oryginalne)`.
3. Znaleziono → `Rag::Answer`. Nie znaleziono → `no_results` + `suggestions`, jak dziś.

### Dlaczego nie fallback po braku wyników

Pierwsza wersja projektu uruchamiała przepisywanie tylko wtedy, gdy `Search` nic nie znalazł —
żeby typowa tura nie kosztowała dodatkowego wywołania. **Sprawdzenie na żywo pokazało, że ten
warunek nigdy się nie spełnia.** Pytanie „a jak to usunąć?” dopasowuje się do instrukcji
„Edycja, dezaktywacja i usuwanie produktu” z dystansem **0,3803**, czyli poniżej progu 0,45.
Wyszukiwarka chwyta każdą instrukcję zawierającą słowo „usunąć”; dopiero model widzi, że to nie
na temat.

Odrzucony został też warunek „gdy model odmówi” (`status: :not_in_docs`): BRO-27 celowo
ograniczał fałszywe odmowy, więc na źle dopasowanym fragmencie model chętnie odpowie — tylko
o usuwaniu produktu zamiast adresu dostawy. Odmowy by nie było, a użytkownik dostałby pewną
i błędną odpowiedź.

Decyzję „czy to pytanie wymaga kontekstu” podejmuje więc model w `QuestionRewriter`, bo to
jedyne miejsce, które widzi historię. Cena: jedno krótkie wywołanie (64 tokeny wyjścia) w każdej
turze po pierwszej.

Pomiar na kanonicznym przykładzie: „a jak to usunąć?” + historia → „Jak usunąć adres dostawy
klienta?” → `docs/user/edycja-i-usuwanie-adresu-dostawy-klienta.md` z dystansem **0,2380**
(zamiast fałszywego trafienia 0,3803).

## Komponenty

| element | rola | zależności |
| --- | --- | --- |
| `Rag::QuestionRewriter` | historia + pytanie → jedno samodzielne pytanie | `GeminiClient` |
| `Rag::Ask` | orkiestracja kroków 1-4 | `Search`, `QuestionRewriter`, `Answer` |

`Search`, `Retriever`, `Embedder`, `Answer`, `GeminiClient` — bez zmian w zachowaniu.
`Api::AsksController` woła `Rag::Ask` zamiast `Search` + `Answer` i pozostaje cienki.

### Rag::QuestionRewriter

- Własny, krótki prompt systemowy: przepisz ostatnie pytanie na samodzielne, korzystając z
  poprzednich pytań; nie dopisuj informacji, których w nich nie ma; jeśli pytanie jest już
  samodzielne, zwróć je bez zmian; zwróć samo pytanie, bez komentarza.
- `max_output_tokens` 64 — wynikiem jest jedno zdanie.
- `RAG_GEMINI_REWRITE_TIMEOUT`, domyślnie **10 s**, i **zero** ponowień, zamiast 90 s i dwóch
  ponowień jak w `Answer`. Przepisanie jest ulepszeniem, które w razie niepowodzenia degraduje się
  do zachowania sprzed zmiany, więc czekanie nic nie daje. Zmierzone: jedno przepisanie potrafiło
  zająć 25 s, a ogon Gemini sięgał 161 s.
- Zwraca `nil`, gdy Gemini jest wyłączone, zwróci pustą treść albo zgłosi błąd. `nil` oznacza
  „brak przepisania” i prowadzi prosto do kroku 4, czyli do zachowania sprzed zmiany.

### Rag::Ask

Zwraca strukturę, z której kontroler buduje dzisiejszy JSON: wynik `Answer` oraz `search_result`
użyty do odpowiedzi (do `suggestions`). Przepisane pytanie trafia do logu, nie do odpowiedzi HTTP.

## Obsługa błędów

| sytuacja | zachowanie |
| --- | --- |
| Gemini wyłączone (brak klucza lub środowisko inne niż development) | przepisywanie nieaktywne, wynik jak dziś. Wyszukiwarka musi działać bez Gemini |
| `QuestionRewriter` zgłasza błąd lub przekroczy timeout | wyszukiwanie po pytaniu oryginalnym, czyli wynik jak dziś; ostrzeżenie w logu |
| Redis albo Ollama niedostępne | bez zmian: 503, obsługa w kontrolerze |
| `history` nie jest tablicą stringów | ignorowana (traktowana jak brak historii) |

## Testy

- `QuestionRewriter` na atrapie `FakeGemini`: przepisuje z historią, zwraca `nil` przy błędzie,
  `nil` przy pustej odpowiedzi, nie woła API przy wyłączonym Gemini.
- `Ask`: bez historii nie woła przepisywania i szuka raz; z historią przepisuje **także wtedy, gdy
  oryginał coś by znalazł** (to jest sedno zmiany); `nil` z przepisywania oznacza wyszukiwanie po
  pytaniu oryginalnym.
- Request spec `/api/ask`: żądanie z `history`, obcinanie limitów, zgodność wstecz bez `history`.
- Ewaluacja: `golden.yml` zyskuje opcjonalne pole `history`, a `rag:eval` liczy Recall@3 i MRR
  osobno dla pytań jednoturowych i dla rozmów — tą samą ścieżką co API (`Ask.resolve_question`),
  bez własnej kopii warunku.

## Kryterium sukcesu

- Recall@3 i MRR na pytaniach jednoturowych bez regresji (dziś 0,98 / 0,90).
- Rozmowy wielotury w `golden.yml` trafiają w oczekiwane pliki — liczba do ustalenia pierwszym
  pomiarem, bo dziś nie ma punktu odniesienia.
- Pierwsza tura rozmowy (pusta `history`) nie zwalnia ani o milisekundę: przepisywanie się nie
  uruchamia. Kolejne tury płacą jedno krótkie wywołanie, ograniczone timeoutem 10 s bez ponowień.
