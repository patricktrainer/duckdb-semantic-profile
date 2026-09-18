-- ─────────────────────────────────────────────────────────────────────────────
-- The probe catalog: value-level and row-level checks that a statistical
-- profiler structurally cannot run, because each one is a question about meaning.
--
-- `{col}` and `{type}` are substituted per column at selection time. Probes are
-- candidates, not a checklist -- step 2 decides which ones this table warrants.
--
-- `needs_confident_type` marks probes whose whole premise is that discovery got
-- the semantic type right. Those are skipped when the type was a coin flip,
-- because otherwise a shaky classification turns into a confident false positive
-- on every row.
--
-- To add your own: CREATE OR REPLACE MACRO profile_catalog() wrapping this
-- one with UNION ALL. Nothing here is compiled into the extension binary.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE MACRO profile_catalog() AS TABLE
SELECT * FROM (VALUES
    -- ── value scope ────────────────────────────────────────────────────────
    ('placeholder_or_test_value', 'value', ['*'], false,
     'Is the value in `row.{col}` a placeholder, test entry or filler rather than a real observation?',
     json_object(
        'true',  json_object('what', 'Fabricated, sample or stand-in data.',
                             'examples', json_array('Test User', 'asdf', 'John Doe', 'foo@bar.com', '123 Main St', 'lorem ipsum', 'DELETEME')),
        'false', 'A plausible real-world value for this field.')),

    ('type_mismatch', 'value', ['*'], true,
     'The column `{col}` holds {type}. Is the value in `row.{col}` something other than that?',
     json_object(
        'true',  'The value is not a {type} at all, or belongs to a different kind of field.',
        'false', 'The value is a {type}, even if oddly formatted.')),

    ('embedded_pii', 'value', ['free_text', 'category_label', 'json_blob', 'other', 'file_path', 'url'], false,
     'Does the value in `row.{col}` contain personal information about an identifiable person, in a field that is not meant to hold it?',
     json_object(
        'true',  json_object('what', 'Personal data appearing incidentally inside another field.',
                             'examples', json_array('a note containing a national ID number', 'a comment quoting a home address', 'a description naming a customer and their medical condition')),
        'false', 'No personal information is present.')),

    ('credential_exposed', 'value', ['free_text', 'json_blob', 'other', 'url', 'file_path'], false,
     'Does the value in `row.{col}` expose a secret: a password, API key, token or connection string?',
     json_object('true', 'A credential is present in the value.', 'false', 'No credential is present.')),

    ('unit_ambiguous', 'value', ['currency_amount', 'physical_measurement', 'percentage', 'count_or_quantity', 'duration'], false,
     'Taking the value in `row.{col}` together with the rest of the row, is it impossible to tell what unit or currency it is expressed in?',
     json_object(
        'true',  json_object('what', 'The magnitude is stated but the unit is not recoverable.',
                             'examples', json_array('a bare 26.4 in a column where other rows say `12 kg`', 'an amount with no currency where rows use different currencies')),
        'false', 'The unit is stated in the value, the column name, or a neighbouring column.')),

    ('operational_note_in_data_field', 'value', ['street_address', 'person_name', 'organization_name', 'city', 'email_address', 'phone_number', 'sku_or_product_code'], false,
     'Has someone written an instruction, warning or annotation into `row.{col}` instead of the data the field is for?',
     json_object(
        'true',  json_object('what', 'Human process notes stored where a datum belongs.',
                             'examples', json_array('DO NOT SHIP - see ticket 4412', 'address unknown, call first', 'old account, use the new one')),
        'false', 'The field contains only the datum it is meant to hold.')),

    ('multiple_values_in_one_field', 'value', ['email_address', 'phone_number', 'person_name', 'organization_name', 'sku_or_product_code', 'url', 'country', 'city'], false,
     'Does `row.{col}` pack more than one distinct value into a single field?',
     json_object(
        'true',  'Two or more separate values are crammed in, however they are delimited.',
        'false', 'Exactly one value is present.')),

    ('truncated_value', 'value', ['*'], false,
     'Does the value in `row.{col}` look cut off mid-way rather than complete?',
     json_object(
        'true',  'The value ends abruptly, as though it hit a length limit.',
        'false', 'The value looks complete.')),

    ('mojibake', 'value', ['*'], false,
     'Does the value in `row.{col}` show signs of character-encoding damage?',
     json_object(
        'true',  json_object('what', 'Text mangled by a wrong encoding round-trip.',
                             'examples', json_array('Ã© where é was meant', 'â€™ where an apostrophe was meant', 'stray replacement characters')),
        'false', 'The text is intact.')),

    ('impossible_for_domain', 'value', ['currency_amount', 'physical_measurement', 'percentage', 'count_or_quantity', 'duration', 'date', 'timestamp', 'geo_coordinate'], false,
     'Given what `{col}` measures, is the value in `row.{col}` outside the range that is actually possible?',
     json_object(
        'true',  json_object('what', 'Physically or logically impossible, as opposed to merely unusual.',
                             'examples', json_array('a negative shipped quantity', 'a human age of 900', 'a birth date in the future', 'a percentage of 400')),
        'false', 'The value is possible, even if it is an outlier.')),

    ('sentinel_used_as_value', 'value', ['*'], false,
     'Is the value in `row.{col}` a stand-in for missing data rather than a real measurement?',
     json_object(
        'true',  json_object('what', 'A magic value meaning "we do not know".',
                             'examples', json_array('-1 for an unknown count', '9999-12-31', '0 meaning not recorded', 'N/A', 'unknown')),
        'false', 'A genuine recorded value.')),

    ('wrong_granularity', 'value', ['date', 'timestamp', 'duration'], false,
     'Is the value in `row.{col}` recorded at a different time granularity from the rest of the column?',
     json_object(
        'true',  'The precision differs, e.g. a date-only value among full timestamps, or midnight-padded values mixed with real times.',
        'false', 'The granularity matches the rest of the column.')),

    ('language_mismatch', 'value', ['free_text', 'category_label', 'city', 'organization_name'], false,
     'Is the value in `row.{col}` written in a different language from the rest of the column?',
     json_object('true', 'A different language or script from its neighbours.', 'false', 'Consistent with the rest of the column.')),

    ('internal_code_leaked', 'value', ['free_text', 'category_label', 'organization_name', 'sku_or_product_code'], false,
     'Has an internal system code, ticket reference or debug string leaked into `row.{col}` where a human-readable value belongs?',
     json_object('true', 'An internal artefact is showing through.', 'false', 'The value is meant for human consumption.')),

    -- ── row scope ──────────────────────────────────────────────────────────
    ('geo_inconsistent', 'row', ['*'], false,
     'Do the geographic fields in this row disagree with each other?',
     json_object(
        'true',  json_object('what', 'Two location fields that cannot both be right.',
                             'examples', json_array('country US with postal code SW1A 1AA', 'city Paris in region Texas', 'coordinates that fall in a different country from the stated one')),
        'false', 'The geographic fields are mutually consistent, or there are too few to conflict.')),

    ('status_timeline_inconsistent', 'row', ['*'], false,
     'Does this row''s status disagree with its timestamps or with the events they imply?',
     json_object(
        'true',  json_object('what', 'The lifecycle state and the recorded times contradict each other.',
                             'examples', json_array('status shipped but the shipped timestamp is missing', 'a delivery date before the order date', 'status cancelled alongside a completion timestamp')),
        'false', 'Status and timing agree, or the row has no timeline to contradict.')),

    ('quantity_amount_mismatch', 'row', ['*'], false,
     'Do the numeric fields in this row fail to add up against one another?',
     json_object(
        'true',  json_object('what', 'An arithmetic relationship the row implies does not hold.',
                             'examples', json_array('unit price times quantity does not match the total', 'a discount larger than the subtotal', 'parts that do not sum to the stated whole')),
        'false', 'The numbers are consistent, or no relationship between them is implied.')),

    ('category_product_mismatch', 'row', ['*'], false,
     'Do the descriptive fields in this row describe different things from one another?',
     json_object(
        'true',  json_object('what', 'Fields that should agree about what the row is describe unrelated things.',
                             'examples', json_array('a product named "Blue T-Shirt" filed under category "Garden Tools"', 'a description that does not match the item name')),
        'false', 'The descriptive fields agree.')),

    ('row_is_test_data', 'row', ['*'], false,
     'Taken as a whole, is this row test or demo data that has ended up in a real dataset?',
     json_object(
        'true',  'The row as a whole reads as fabricated, seeded or left over from testing.',
        'false', 'The row reads as a genuine record.')),

    ('internally_contradictory', 'row', ['*'], false,
     'Setting aside anything already covered by the other checks, do any two fields in this row contradict each other?',
     json_object(
        'true',  'Two fields make claims that cannot both be true.',
        'false', 'Nothing in the row contradicts anything else in it.'))
) AS t(probe_id, scope, applies_to, needs_confident_type, instructions, criteria);
