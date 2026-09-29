# Ingest the public datasets the DATASETS page reads.
#
# The prompts come from DiffusionDB (poloclub), CC0-1.0. Its metadata table is a
# 194MB parquet listing 2M prompts with the hyperparameters their authors used,
# and its EXPLORER data adds the two things that make a prompt browsable: the
# dataset's own 2-D projection of prompt space, its derived topic labels, and the
# phrase tree it counted over 2M prompts.
#
# The two halves are joined on the prompt TEXT, because they are two readings of
# the same 2M prompts and the text is the only key both carry:
#
#   * coords  — `umap-60k.json`      {xs, ys, prompts}: 60,000 prompts, projected
#   * topics  — `umap-1m-topic-data.json`  labelled grid points in the SAME space
#   * roots   — `phrases-tree.json`  a phrase tree with counts over 2M prompts
#   * settings— `metadata.parquet`   seed/step/cfg/sampler/size, per prompt
#
# WHAT THE COLUMN NAMES MEAN: the studio stores the FLUX contract's word for a
# hyperparameter (`guidance`, `steps`) and records the dataset's own field
# (`cfg`, `step`) in `meta`, so a reader can always get back to the source's own
# vocabulary. That mapping is the only translation this task performs.
#
# WHERE THE INPUT FILES COME FROM — the sources are NOT committed (they are large
# and belong to somebody else). Fetch them into the directory this task reads:
#
#   export D=~/chopshop-studio/storage/datasets/diffusiondb
#   mkdir -p "$D"
#   curl -L -o "$D/umap-60k.json"            https://raw.githubusercontent.com/poloclub/diffusiondb/main/explorer/data/umap-60k.json
#   curl -L -o "$D/umap-1m-topic-data.json"  https://raw.githubusercontent.com/poloclub/diffusiondb/main/explorer/data/umap-1m-topic-data.json
#   curl -L -o "$D/phrases-tree.json"        https://raw.githubusercontent.com/poloclub/diffusiondb/main/explorer/data/phrases-tree.json
#   curl -L -o "$D/metadata.parquet"         https://huggingface.co/datasets/poloclub/diffusiondb/resolve/main/metadata.parquet
#   python3 -c "import pyarrow" || pip install pyarrow   # or: uv run --with pyarrow
#
#   bin/rails datasets:ingest_diffusiondb            # every prompt the map covers
#   bin/rails datasets:ingest_diffusiondb LIMIT=5000 # a shorter slice
#
# Re-running replaces the diffusiondb rows rather than appending: the library is
# a SLICE of somebody else's dataset, and "ingest twice" must mean one library,
# not two.
namespace :datasets do
  desc "Ingest DiffusionDB prompts (coords, topics, phrase roots, hyperparameters) into prompt_sources"
  task ingest_diffusiondb: :environment do
    source_dir = Pathname.new(ENV["SOURCE_DIR"].presence ||
                              Rails.root.join("storage", "datasets", "diffusiondb").to_s)
    limit = ENV["LIMIT"].to_i.positive? ? ENV["LIMIT"].to_i : nil

    puts "source dir: #{source_dir}"
    missing = %w[umap-60k.json phrases-tree.json umap-1m-topic-data.json].reject do |name|
      source_dir.join(name).exist?
    end
    if missing.any?
      abort "missing #{missing.join(', ')} in #{source_dir} — see the header of this task for the " \
            "URLs to fetch them from"
    end

    map = JSON.parse(source_dir.join("umap-60k.json").read)
    prompts = map.fetch("prompts")
    xs = map.fetch("xs")
    ys = map.fetch("ys")
    puts "the map covers #{prompts.size} prompts"

    topics, topic_count = topic_lookup(source_dir.join("umap-1m-topic-data.json"))
    roots, root_count = root_lookup(source_dir.join("phrases-tree.json"))
    puts "topic labels: #{topic_count} grid points · phrase-tree roots: #{root_count}"

    # The hyperparameters, keyed by prompt text: one streaming pass over the
    # parquet dump (2M lines, ~1GB) and only the mapped prompts are kept.
    settings = settings_lookup(source_dir, prompts)

    rows = []
    prompts.each_with_index do |prompt, i|
      break if limit && rows.size >= limit
      text = prompt.to_s.strip
      next if text.empty?

      # EVERY key, always: `PromptSource.ingest` builds one statement per slice,
      # so a row missing a key is an insert that refuses the whole batch. The keys
      # a row has no value for are the columns the dataset did not record, and
      # they are written as nil rather than left out.
      row = {
        dataset: "diffusiondb",
        licence: PromptSource::DATASETS.dig("diffusiondb", "licence"),
        attribution: PromptSource::DATASETS.dig("diffusiondb", "attribution"),
        part: settings.dig(text, :meta, "part_id"),
        image_name: nil, prompt: text, prompt_sha: nil,
        seed: nil, steps: nil, guidance: nil, sampler: nil, width: nil, height: nil,
        nsfw: nil,
        topic: topics.call(xs[i], ys[i]),
        phrase_root: roots.call(text),
        x: xs[i], y: ys[i], meta: {}
      }
      row.merge!(settings[text] || {})
      rows << row
    end

    puts "mapped prompts to ingest: #{rows.size} (#{settings.size} carry hyperparameters)"

    PromptSource.transaction do
      removed = PromptSource.for_dataset("diffusiondb").delete_all
      puts "replaced #{removed} existing diffusiondb rows"
      # `PromptSource.ingest`, not `insert_all`: the model owns the normalisation
      # and the checksum, and insert_all would run neither.
      written = PromptSource.ingest(rows)
      puts "wrote #{written} rows"
    end

    puts "library now: #{PromptSource.count} rows — #{PromptSource.census.inspect}"
  end

  desc "Check the ingested prompt library against the postgres of its sources"
  task verify_library: :environment do
    census = PromptSource.census
    puts JSON.pretty_generate(census)
    abort "the library is empty" if census["total"].to_i.zero?
    abort "no mapped rows: the map sheet would draw nothing" if census["mapped"].to_i.zero?
    puts "ok: #{census['mapped']} of #{census['total']} rows carry coordinates"
  end
end

# --- the joins, each one a small, stated rule ------------------------------

# The topic a point falls in, from the dataset's labelled grid: the NEAREST
# labelled point, within a radius. A grid point is a cell's label and not a
# scatter the point has to land on, so "nearest" is the honest reading — and
# beyond the radius the answer is nil rather than the nearest label however far
# away, which would paint every empty region as its neighbour's topic.
def topic_lookup(path)
  data = JSON.parse(path.read).fetch("data")
  points = data.values.flatten(1).map { |x, y, label| [x.to_f, y.to_f, label.to_s] }
  radius = 1.5 # grid cells are 1.0 apart in the source's own units

  lookup = lambda do |x, y|
    return nil if x.nil? || y.nil?

    best = nil
    best_d = radius
    points.each do |px, py, label|
      d = Math.sqrt(((px - x)**2) + ((py - y)**2))
      if d < best_d
        best = label
        best_d = d
      end
    end
    best
  end
  [lookup, points.size]
end

# The most frequent phrase-tree root the prompt actually contains: a whole-word
# test, longest match first, so "art" does not win over "artstation" and "8k"
# does not match inside "128k". Frequencies are the tree's own counts over 2M
# prompts, which is why the most frequent MATCH is the right answer rather than
# the first match.
def root_lookup(path)
  tree = JSON.parse(path.read)
  entries = []
  walk = lambda do |node|
    entries << [node["n"].to_s.downcase, node["v"].to_i] if node["n"]
    Array(node["c"]).each { |child| walk.call(child) }
  end
  walk.call(tree)
  entries.reject! { |name, _v| name.length < 3 }
  entries.sort_by! { |name, v| [-v, -name.length] }
  by_length = entries.sort_by { |name, _v| -name.length }
  patterns = by_length.map do |name, v|
    [name, v, Regexp.new("(?<![\\w-])#{Regexp.escape(name)}(?![\\w-])", Regexp::IGNORECASE)]
  end

  lookup = lambda do |text|
    found = patterns.find { |_name, _v, re| text.match?(re) }
    found && found[0]
  end
  [lookup, patterns.size]
end

# The parquet dump, streamed. The dump is JSONL produced by
# `read_parquet.py` — one row per line, converted out of parquet by a throwaway
# environment — so this needs no parquet reader of its own and holds only the
# prompts the map already covers.
def settings_lookup(source_dir, prompts)
  path = source_dir.join("metadata-slice.jsonl")
  wanted = prompts.to_h { |p| [p.to_s.strip, true] }
  out = {}
  return out unless path.exist?

  File.foreach(path) do |line|
    row = JSON.parse(line) rescue nil
    next unless row
    text = row["prompt"].to_s.strip
    next unless wanted.key?(text)
    next if out.key?(text) # first occurrence wins: the dump is in part order

    out[text] = {
      seed: row["seed"], steps: row["step"], guidance: row["cfg"],
      sampler: row["sampler"], width: row["width"], height: row["height"],
      image_name: row["image_name"], nsfw: row["prompt_nsfw"],
      meta: { "part_id" => row["part_id"], "user_name" => row["user_name"],
              "timestamp" => row["timestamp"], "image_nsfw" => row["image_nsfw"],
              "source_fields" => { "guidance" => "cfg", "steps" => "step" } }
    }
  end
  puts "read #{out.size} hyperparameter rows from #{File.basename(path.to_s)}"
  out
end
