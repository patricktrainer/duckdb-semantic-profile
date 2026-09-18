-- ─────────────────────────────────────────────────────────────────────────────
-- L0: typed access to TypeSafe System One judgments.
--
-- ts_ask(state, questions) is the only function that reaches the network. It
-- takes N questions and answers them in ONE request. Answers are independent of
-- what else is in the request, so batching costs nothing in accuracy and saves
-- re-sending state per question -- which is where the tokens actually go.
--
-- Everything below is pure JSON shaping over that one call.
-- ─────────────────────────────────────────────────────────────────────────────

-- The answers object from a batched call. Question ids are yours to choose.
CREATE OR REPLACE MACRO ts_answers(state, questions) AS
    json_extract(ts_ask(state::VARCHAR, questions::VARCHAR), '$.answers');

-- Did the call fail? ts_ask reports soft failures in-band so one bad row cannot
-- sink a long profiling run; these two let SQL see that.
CREATE OR REPLACE MACRO ts_error(state, questions) AS
    json_extract_string(ts_ask(state::VARCHAR, questions::VARCHAR), '$.error');

-- Question constructors. `criteria` is optional structure; pass NULL to omit it.
CREATE OR REPLACE MACRO q_noul(instructions, criteria) AS
    json_object('type', 'noul', 'instructions', instructions, 'criteria', criteria);
CREATE OR REPLACE MACRO q_choice(instructions, criteria) AS
    json_object('type', 'choice', 'instructions', instructions, 'criteria', criteria);
CREATE OR REPLACE MACRO q_score(instructions, criteria) AS
    json_object('type', 'score', 'instructions', instructions, 'criteria', criteria);

-- Extractors, applied to the result of ts_answers. These make no API calls, so
-- pulling ten answers out of one batched response is free.
CREATE OR REPLACE MACRO noul_of(answers, id) AS
    TRY_CAST(json_extract(answers, '$."' || id || '".noul') AS DOUBLE);

CREATE OR REPLACE MACRO choice_of(answers, id) AS struct_pack(
    choice        := json_extract_string(answers, '$."' || id || '".choice'),
    confidence    := TRY_CAST(json_extract(answers, '$."' || id || '".confidence') AS DOUBLE),
    probabilities := json_extract(answers, '$."' || id || '".probabilities')
);

CREATE OR REPLACE MACRO score_of(answers, id) AS struct_pack(
    score         := TRY_CAST(json_extract(answers, '$."' || id || '".score') AS DOUBLE),
    confidence    := TRY_CAST(json_extract(answers, '$."' || id || '".confidence') AS DOUBLE),
    probabilities := json_extract(answers, '$."' || id || '".probabilities')
);

-- One-shot convenience wrappers for interactive use. Inside the pipeline we
-- always batch instead, because a wrapper is one request per question.
CREATE OR REPLACE MACRO ts_noul(state, instructions) AS
    noul_of(ts_answers(state, json_object('q', q_noul(instructions, NULL))), 'q');
CREATE OR REPLACE MACRO ts_choice(state, instructions, criteria) AS
    choice_of(ts_answers(state, json_object('q', q_choice(instructions, criteria))), 'q');
CREATE OR REPLACE MACRO ts_score(state, instructions, criteria) AS
    score_of(ts_answers(state, json_object('q', q_score(instructions, criteria))), 'q');
