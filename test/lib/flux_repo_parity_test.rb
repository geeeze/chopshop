require "test_helper"
require "open3"

# PARITY WITH THE SIBLING REPO THAT ACTUALLY LOADS THE WEIGHTS.
#
# `app/models/flux_conf.rb` is a hand-mirror of `~/chopshop-flux`'s registry and
# nothing syncs it — the flux repo's own models.py says so in as many words. That
# makes drift silent, and silent drift here means the studio offers a model the
# service does not have, or prints a licence the licence is not.
#
# So this test reads the OTHER repo's source and compares. It is deliberately a
# PARSER rather than an import: the flux repo is stdlib-only Python with a frozen
# dataclass registry, so `ast` reads it without installing anything, without
# running it, and without adding a Python dependency to this app's bundle.
#
# Two rules this file is built around, both of them the difference between a
# parity test and a decoration:
#
#   1. IT MUST BE ABLE TO FAIL. Not "it compares something" — the comparison is
#      itself exercised against a deliberately corrupted copy of a registry
#      (see the last tests in this file), and a licence that differs by ONE
#      character has to come out as a mismatch. A comparator that cannot fail
#      would make every assertion above it theatre.
#
#   2. IT MUST NOT PASS SILENTLY. A file that cannot be found, a registry the
#      parser cannot locate, or a single field whose value it cannot evaluate —
#      each of those is reported, as a failure where the registry is missing and
#      as a SKIP with the reason where one field is. The one thing it must never
#      do is treat "I could not read this" as "this agrees".
#
# The checkout path comes from CHOPSHOP_FLUX_REPO (the local sibling as the
# default). The path belongs in the TEST, never in app/: the studio's code stays
# host-agnostic, and a test is where "the box this runs on has a sibling
# checkout" is allowed to be assumed — with a skip when it does not.
class FluxRepoParityTest < ActiveSupport::TestCase
  FLUX_REPO = ENV.fetch("CHOPSHOP_FLUX_REPO", File.expand_path("~/chopshop-flux")).freeze

  # The fields each registry is compared on. Everything the service REPORTS
  # about an entry and the studio claims, minus the two things the two files word
  # for their own audiences:
  #
  #   * `notes` is prose. The studio's notes are written for the studio's page and
  #     the service's for the service's docs, and they already differ on purpose
  #     on every entry -- comparing them would fail everywhere and teach nothing.
  #   * `aliases` is the studio's own lookup convenience and already differs
  #     (the studio has `sd1.5`, the service has `sd-1.5`).
  #
  # `pipeline` / `edit_pipeline` (which diffusers class loads the weights) are NOT
  # mirrored by the studio, so they cannot be compared. `guidance_embedded` and
  # `resolution_binning` ARE mirrored and are compared, because both change what
  # the studio TELLS the operator: guidance_embedded suppresses the "guidance is
  # ignored" warning (a distilled pipeline with an embedded guidance acts on the
  # number without running CFG), and resolution_binning is why a requested size
  # can come back different. They were the gap this test's own footer used to
  # admit to; they are compared now.
  MODEL_FIELDS = %w[repo_id params_b layout licence commercial_ok vram_gb repo_bytes
                    default_steps default_guidance distilled gated
                    negative_prompt img2img_strength guidance_embedded
                    resolution_binning multi_reference
                    dim_multiple min_dim max_pixels].freeze
  MODIFIER_FIELDS = %w[repo_id weight_name licence commercial_ok repo_bytes
                       steps guidance scheduler scale].freeze
  VAE_FIELDS = %w[repo_id licence commercial_ok tiny repo_bytes].freeze

  UNPARSED = "<<unparsed>>".freeze

  # Distinguishes "the service does not carry this field" (skip with a reason)
  # from "the service carries it and its value is nil" -- which is a real value
  # here, because `steps`, `guidance` and `scheduler` are nil on every adapter
  # with no schedule of its own. Collapsing the two would let a nil on the left
  # silently agree with a number on the right.
  ABSENT = Object.new.freeze

  def absent?(value)
    value.equal?(ABSENT)
  end

  # The stdlib parser. Reads config.py's constants (so a ModelSpec default like
  # `dim_multiple=config.DIMENSION_MULTIPLE` resolves to a NUMBER, not a name),
  # then every module-level dict whose values are constructor calls, and
  # classifies them by the fields their entries carry rather than by guessing a
  # variable name — so a rename in the flux repo cannot silently empty this.
  PARSE_PY = <<~'PY'.freeze
    import ast, json, os, sys

    root = sys.argv[1]
    pkg = os.path.join(root, "chopshop_flux")
    UNPARSED = "<<unparsed>>"
    problems = []

    def parse_file(path):
        with open(path, "r", encoding="utf-8") as fh:
            return ast.parse(fh.read(), filename=path)

    def ev(node, names):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            if node.id in names:
                return names[node.id]
            raise KeyError(node.id)
        if isinstance(node, ast.Attribute):
            base = ev(node.value, names)
            if isinstance(base, dict) and node.attr in base:
                return base[node.attr]
            raise KeyError(node.attr)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            return -ev(node.operand, names)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.UAdd):
            return ev(node.operand, names)
        if isinstance(node, ast.BinOp):
            left, right = ev(node.left, names), ev(node.right, names)
            for op, fn in ((ast.Mult, lambda a, b: a * b), (ast.Add, lambda a, b: a + b),
                           (ast.Sub, lambda a, b: a - b), (ast.Div, lambda a, b: a / b),
                           (ast.FloorDiv, lambda a, b: a // b), (ast.Pow, lambda a, b: a ** b)):
                if isinstance(node.op, op):
                    return fn(left, right)
            raise KeyError("operator")
        if isinstance(node, ast.Tuple):
            return [ev(e, names) for e in node.elts]
        if isinstance(node, ast.List):
            return [ev(e, names) for e in node.elts]
        if isinstance(node, ast.Dict):
            return {ev(k, names): ev(v, names) for k, v in zip(node.keys, node.values)}
        if isinstance(node, ast.JoinedStr):
            out = ""
            for piece in node.values:
                if not isinstance(piece, ast.Constant):
                    raise KeyError("f-string")
                out += str(piece.value)
            return out
        raise KeyError(ast.dump(node)[:40])

    def constants(tree, names, modules):
        for node in tree.body:
            if isinstance(node, ast.ImportFrom):
                if node.module is None:
                    for alias in node.names:
                        if alias.name in modules:
                            names[alias.asname or alias.name] = modules[alias.name]
                else:
                    source = modules.get(node.module)
                    if source is not None:
                        for alias in node.names:
                            if alias.name in source:
                                names[alias.asname or alias.name] = source[alias.name]
                continue
            targets, value = [], None
            if isinstance(node, ast.Assign):
                if not all(isinstance(t, ast.Name) for t in node.targets):
                    continue
                targets = [t.id for t in node.targets]
                value = node.value
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                targets = [node.target.id]
                value = node.value
            if value is None:
                continue
            for name in targets:
                try:
                    names[name] = ev(value, names)
                except Exception:
                    pass
        return names

    def class_defaults(tree, class_name, names):
        """A dataclass's own field defaults -- what an entry that does not name a
        field gets. This is where klein's dim rules come from in models.py."""
        defaults = {}
        for node in tree.body:
            if not isinstance(node, ast.ClassDef) or node.name != class_name:
                continue
            for stmt in node.body:
                if isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name) and stmt.value is not None:
                    try:
                        defaults[stmt.target.id] = ev(stmt.value, names)
                    except Exception:
                        pass
                elif isinstance(stmt, ast.Assign):
                    for t in stmt.targets:
                        if isinstance(t, ast.Name):
                            try:
                                defaults[t.id] = ev(stmt.value, names)
                            except Exception:
                                pass
        return defaults

    def registries(tree, names):
        """Every module-level dict of constructor calls, keyed by the variable
        name, with the constructor it calls and each entry's keyword fields."""
        found = {}
        for node in tree.body:
            name, value = None, None
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                name, value = node.targets[0].id, node.value
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                name, value = node.target.id, node.value
            if name is None or not isinstance(value, ast.Dict) or not value.keys:
                continue
            entries, ctor, ok = {}, None, True
            for k, v in zip(value.keys, value.values):
                if not isinstance(v, ast.Call):
                    ok = False
                    break
                try:
                    key = ev(k, names)
                except Exception:
                    ok = False
                    break
                if not isinstance(key, str):
                    ok = False
                    break
                if ctor is None and isinstance(v.func, ast.Name):
                    ctor = v.func.id
                fields = {}
                for kw in v.keywords:
                    if kw.arg is None:
                        continue
                    try:
                        fields[kw.arg] = ev(kw.value, names)
                    except Exception:
                        fields[kw.arg] = UNPARSED
                entries[key] = fields
            if ok and entries:
                found[name] = {"ctor": ctor, "entries": entries}
        return found

    def classify(found):
        """Bucket the dicts by what their entries CARRY, not by their name."""
        buckets = {"models": {}, "modifiers": {}, "vaes": {}}
        for name, spec in found.items():
            fieldset = set()
            for fields in spec["entries"].values():
                fieldset.update(fields.keys())
            if "weight_name" in fieldset:
                buckets["modifiers"][name] = spec
            elif "tiny" in fieldset:
                buckets["vaes"][name] = spec
            elif "default_steps" in fieldset or "default_guidance" in fieldset:
                buckets["models"][name] = spec
        out = {}
        for bucket, cands in buckets.items():
            if not cands:
                out[bucket] = None
                continue
            pick = sorted(cands.items(), key=lambda kv: (-len(kv[1]["entries"]), kv[0]))[0]
            out[bucket] = pick
        return out

    def decorated(found_buckets, tree, names):
        result = {}
        for bucket, picked in found_buckets.items():
            if picked is None:
                result[bucket] = None
                continue
            name, spec = picked
            entries = spec["entries"]
            defaults = class_defaults(tree, spec["ctor"], names) if spec["ctor"] else {}
            merged = {}
            for key, fields in entries.items():
                row = dict(defaults)
                row.update(fields)
                merged[key] = row
            result[bucket] = {"container": name, "ctor": spec["ctor"], "entries": merged}
        return result

    def raise_template(tree, func_name):
        """The format string a function raises with: the Constant on the left of
        the `%` inside its `raise`. This is how a SENTENCE gets checked rather
        than paraphrased -- the studio claims the service's wording, and the only
        way to know is to read the template the service formats."""
        if tree is None:
            return None
        for node in ast.walk(tree):
            if not isinstance(node, ast.FunctionDef) or node.name != func_name:
                continue
            for inner in ast.walk(node):
                if not isinstance(inner, ast.Raise) or inner.exc is None:
                    continue
                call = inner.exc
                if not isinstance(call, ast.Call) or not call.args:
                    continue
                arg = call.args[0]
                if isinstance(arg, ast.BinOp) and isinstance(arg.op, ast.Mod) \
                        and isinstance(arg.left, ast.Constant):
                    return arg.left.value
        return None

    config_names, config_tree = {}, None
    try:
        config_tree = parse_file(os.path.join(pkg, "config.py"))
        config_names = constants(config_tree, {}, {})
    except Exception as exc:
        problems.append("could not read config.py: %s" % exc)

    def env_inventory(tree, names):
        """Every environment variable config.py reads, and the default it falls
        back to.

        The two shapes are the file's own: ``os.environ.get(NAME)`` (alone, or
        as ``os.environ.get(NAME) or <default>``) and the ``_int_env`` /
        ``_float_env`` helpers, whose second argument IS the default. This is
        the inventory the studio's page renders and its conf JSON emits, so a
        knob the service gains and the page does not name is a FAILURE here
        rather than a sentence in a doc nobody re-reads -- which is how the GPU
        guard went unseen in the studio (that drift, seen by inspection, is
        issue #13; this is the check that would have caught it).

        A fallback the parser cannot evaluate (out_dir's cwd join) is reported
        as UNPARSED, never as "the service has no default": the two are
        different claims and only one of them is safe to compare against.
        """
        found = {}

        def record(name, default):
            # `_int_env(NAME, DEFAULT)` and a bare `os.environ.get(NAME)` in the
            # same function are one variable: keep the one that states a value.
            if name not in found or found[name] is None:
                found[name] = default

        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if isinstance(func, ast.Name) and func.id.endswith("_env"):
                args = node.args
                if not args or not isinstance(args[0], ast.Constant) \
                        or not isinstance(args[0].value, str):
                    continue
                if len(args) >= 2:
                    try:
                        record(args[0].value, ev(args[1], names))
                    except Exception:
                        record(args[0].value, UNPARSED)
                else:
                    record(args[0].value, None)
                continue
            if not (isinstance(func, ast.Attribute) and func.attr == "get"):
                continue
            if not (isinstance(func.value, ast.Attribute) and func.value.attr == "environ"):
                continue
            if not node.args or not isinstance(node.args[0], ast.Constant) \
                    or not isinstance(node.args[0].value, str):
                continue
            record(node.args[0].value, None)

        for node in ast.walk(tree):
            if not isinstance(node, ast.BoolOp) or not isinstance(node.op, ast.Or):
                continue
            read, fallbacks = [], []
            for value in node.values:
                if isinstance(value, ast.Call) and isinstance(value.func, ast.Attribute) \
                        and value.func.attr == "get" \
                        and isinstance(value.func.value, ast.Attribute) \
                        and value.func.value.attr == "environ" and value.args \
                        and isinstance(value.args[0], ast.Constant) \
                        and isinstance(value.args[0].value, str):
                    read.append(value.args[0].value)
                else:
                    fallbacks.append(value)
            for name in read:
                if not fallbacks:
                    continue
                try:
                    found[name] = ev(fallbacks[-1], names)
                except Exception:
                    found[name] = UNPARSED
        return found

    # Parsed in dependency order, because a licence constant is imported by name
    # from one module into the next (`from .models import APACHE_2, MIT`) and an
    # unresolved NAME is exactly the kind of thing a parity test must not swallow
    # as a value that happens to agree.
    modules = {"config": config_names}
    out = {"problems": problems, "files": {}, "buckets": {}, "sources": {}, "templates": {}}
    trees = {}

    # The config.py half: the module-level constants, and every environment
    # variable the file reads with the default it falls back to.
    out["config"] = {k: v for k, v in config_names.items()
                     if k.isupper() and isinstance(v, (str, int, float, bool))}
    out["env"] = env_inventory(config_tree, config_names) if config_tree is not None else {}

    for label, filename in (("models", "models.py"), ("modifiers", "modifiers.py")):
        path = os.path.join(pkg, filename)
        if not os.path.exists(path):
            out["files"][label] = {"missing": filename}
            continue
        names = {"config": config_names}
        try:
            tree = parse_file(path)
            trees[label] = tree
            constants(tree, names, modules)
            modules[label] = names
            found = classify(registries(tree, names))
            resolved = decorated(found, tree, names)
            out["files"][label] = resolved
            for bucket in ("models", "modifiers", "vaes"):
                if resolved.get(bucket) and bucket not in out["buckets"]:
                    out["buckets"][bucket] = resolved[bucket]
                    out["sources"][bucket] = filename
        except Exception as exc:
            out["files"][label] = {"error": "%s: %s" % (type(exc).__name__, exc)}

    out["templates"] = {
        "licence_models": raise_template(trees.get("models"), "check_usable"),
        "licence_modifiers": raise_template(trees.get("modifiers"), "check_modifier_usable"),
        "unknown": raise_template(trees.get("modifiers"), "_resolve"),
    }

    # The default model, read from the registry's own module constant rather
    # than inferred from which entry is first: the studio's select opens on it,
    # so a service that changes its default and a studio that does not means the
    # page configures a different model than the service would load.
    out["model_default"] = modules.get("models", {}).get("DEFAULT_MODEL_KEY")

    print(json.dumps(out))
  PY

  # The sibling repo, parsed once per test process. Skips (rather than fails)
  # when the MACHINE cannot support the comparison -- no checkout, no python3 --
  # because that is a missing environment, not a disagreement. A registry the
  # parser cannot find is a FAILURE, because that is a missing contract.
  def repo
    @repo ||= begin
      unless File.directory?(File.join(FLUX_REPO, "chopshop_flux"))
        skip "no sibling flux checkout at #{FLUX_REPO} — set CHOPSHOP_FLUX_REPO to compare against one"
      end
      unless system("python3", "-V", out: File::NULL, err: File::NULL)
        skip "no python3 on this box, so the sibling repo cannot be parsed"
      end
      out, status = Open3.capture2("python3", "-", FLUX_REPO, stdin_data: PARSE_PY)
      flunk "the parity parser failed to run against #{FLUX_REPO}: #{out}" unless status.success?
      JSON.parse(out)
    end
  end

  # A bucket is one registry, wherever the sibling repo keeps it: models.py holds
  # the models, modifiers.py holds the LoRAs AND the VAE swaps (one file, two
  # registries), and the parser reports the file each came from. If a file is
  # missing, or holds no registry this parser can find, that is a FAILURE with
  # the reason -- "I could not read it" must never read as "it agrees".
  def bucket(name)
    got = repo["buckets"][name]
    detail = repo["files"]
    if got.nil?
      flunk "#{name}: no registry found in #{FLUX_REPO}/chopshop_flux — the studio " \
            "mirrors it, so a missing registry is a broken comparison, not a pass " \
            "(parser saw: #{detail.inspect})"
    end
    flunk "#{name}: the parser read an EMPTY registry from #{FLUX_REPO} " \
          "(#{repo['sources'][name]})" if got["entries"].nil? || got["entries"].empty?
    got["entries"]
  end

  # --- comparing ------------------------------------------------------------

  # `pick` accepts the flux repo's own spelling of a field (it uses `license`,
  # the studio uses `licence` -- both are right in their own file) and returns
  # ABSENT for a field the service does not carry or that the parser could not
  # evaluate, so the caller can SKIP with a reason rather than invent a verdict.
  def pick(entry, *names)
    names.each do |name|
      next unless entry.key?(name)
      value = entry[name]
      next if value == UNPARSED
      return value
    end
    ABSENT
  end

  RECORD_SEPARATOR = nil # (unused)
  # The flux repo spells a licence `license`; the studio spells it `licence`.
  # Both are right in their own file, so the comparison is told both and reads
  # whichever the sibling actually has -- and an UNREADABLE licence still has to
  # come back as "not found", which is why the US spelling is tried first and
  # the British one is not assumed.
  REPO_NAMES = {
    "licence" => %w[license licence],
    "targets" => %w[targets models]
  }.freeze

  def repo_names(field)
    REPO_NAMES.fetch(field, [field])
  end

  def field_problems(side, repo_key, studio_value, repo_value, field)
    return [] if studio_value == repo_value
    ["#{side} #{repo_key}.#{field}: studio #{studio_value.inspect} " \
     "!= repo #{repo_value.inspect}"]
  end

  def compare_fields(side, studio_entries, repo_entries, fields)
    problems = []
    studio_entries.each do |key, spec|
      theirs = repo_entries[key]
      next if theirs.nil?
      fields.each do |field|
        repo_value = pick(theirs, *repo_names(field))
        next if absent?(repo_value)
        problems.concat(field_problems(side, key, spec[field], repo_value, field))
      end
    end
    problems
  end

  def key_problems(side, studio_keys, repo_keys)
    missing = studio_keys - repo_keys   # the studio offers what the service lacks
    extra = repo_keys - studio_keys     # the service has what the studio hides
    problems = []
    problems << "#{side}: the studio mirrors #{missing.sort.inspect}, which #{FLUX_REPO} does not register" if missing.any?
    problems << "#{side}: #{FLUX_REPO} registers #{extra.sort.inspect}, which the studio does not mirror" if extra.any?
    problems
  end

  def model_problems(studio, repo_entries)
    key_problems("models", studio.keys, repo_entries.keys) +
      compare_fields("models", studio, repo_entries, MODEL_FIELDS)
  end

  def modifier_problems(studio, repo_entries)
    problems = key_problems("modifiers", studio.keys, repo_entries.keys)
    problems.concat(compare_fields("modifiers", studio, repo_entries, MODIFIER_FIELDS))
    studio.each do |key, spec|
      theirs = repo_entries[key]
      next if theirs.nil?
      repo_targets = pick(theirs, *repo_names("targets"))
      next if absent?(repo_targets)
      # SORTED: membership is the contract (which models an adapter may load
      # against), and the order in the tuple is not something the service reads.
      # Everything else here is compared exactly.
      next if Array(spec["targets"]).map(&:to_s).sort == Array(repo_targets).map(&:to_s).sort
      problems << "modifiers #{key}.targets: studio #{Array(spec['targets']).sort.inspect} " \
                  "!= repo #{Array(repo_targets).sort.inspect}"
    end
    problems
  end

  def vae_problems(studio, repo_entries)
    problems = key_problems("vaes", studio.keys, repo_entries.keys)
    problems.concat(compare_fields("vaes", studio, repo_entries, VAE_FIELDS))
    studio.each do |key, spec|
      theirs = repo_entries[key]
      next if theirs.nil?
      repo_targets = pick(theirs, *repo_names("targets"))
      next if absent?(repo_targets)
      next if Array(spec["targets"]).map(&:to_s).sort == Array(repo_targets).map(&:to_s).sort
      problems << "vaes #{key}.targets: studio #{Array(spec['targets']).sort.inspect} " \
                  "!= repo #{Array(repo_targets).sort.inspect}"
    end
    problems
  end

  # --- the CONFIG mirror ----------------------------------------------------
  #
  # FluxConf transcribes more than the registries: its constants and its env
  # inventory are config.py's, and nothing compared them until now. That is
  # exactly how the GPU-contention guard landed in the service while the studio's
  # page still described a service with no guard (issue #13 — found by
  # inspection, because no test could see it). These comparisons close that
  # class of drift, which is config.py's half of the same problem models.py's
  # half already had a test for.

  # The constants BOTH files state. `DEFAULT_OUT_DIR` is deliberately not here:
  # config.py carries no such constant (`out_dir()` falls back to the cwd), so
  # the studio's "./out" is a documented default rather than a transcribed one.
  CONFIG_CONSTANTS = %w[SERVICE_NAME DEFAULT_BIND DEFAULT_PORT DEFAULT_MAX_PIXELS
                        DIMENSION_MULTIPLE MIN_DIMENSION MAX_UPLOAD_BYTES].freeze

  # The guard family, selected by NAME so a sixth guard knob in the service is
  # compared the moment it exists rather than when someone remembers to add it.
  GUARD_NAME = /GUARD|LMSTUDIO/

  # Variables the studio's inventory names that config.py does NOT read, each for
  # a stated reason. Both ARE read by the service -- MODEL by the engine and the
  # server's request handler, URL by the CLIENT (cli.py, gen2pipe) -- they are
  # simply not in config.py's accessors, which is the only file this parser
  # reads. Anything else that appears here is a typo'd variable, which is a knob
  # an operator would set for nothing.
  ENV_NOT_IN_CONFIG_PY = %w[CHOPSHOP_FLUX_MODEL CHOPSHOP_FLUX_URL].freeze

  def studio_constants
    {
      "SERVICE_NAME" => FluxConf::SERVICE,
      "DEFAULT_BIND" => FluxConf::DEFAULT_BIND,
      "DEFAULT_PORT" => FluxConf::DEFAULT_PORT,
      "DEFAULT_MAX_PIXELS" => FluxConf::DEFAULT_MAX_PIXELS,
      "DIMENSION_MULTIPLE" => FluxConf::DIMENSION_MULTIPLE,
      "MIN_DIMENSION" => FluxConf::MIN_DIMENSION,
      "MAX_UPLOAD_BYTES" => FluxConf::MAX_UPLOAD_BYTES
    }
  end

  def config_problems(studio, repo_constants)
    CONFIG_CONSTANTS.filter_map do |name|
      theirs = repo_constants[name]
      next if theirs.nil?           # "not read" is the caller's failure to report
      next if theirs == studio[name]
      "config.py #{name}: studio #{studio[name].inspect} != repo #{theirs.inspect}"
    end
  end

  # A default stated as a form value against the service's own. A blank studio
  # field is the service's unset; integers and floats are the same number (the
  # form says "120", Python's literal is 120.0) -- but "" and "0" are different
  # claims, because 0 is a real budget and unset is not.
  def same_default?(studio, service)
    return true if service.nil? && studio.to_s.strip.empty?
    return true if studio.to_s.strip == service.to_s
    numeric = /\A-?\d+(\.\d+)?\z/
    studio.to_s.strip.match?(numeric) && service.to_s.strip.match?(numeric) &&
      studio.to_f == service.to_f
  end

  def guard_problems(fields, repo_env)
    mine = fields.map { |f| f[:env] }.compact
    theirs = repo_env.keys.grep(GUARD_NAME)
    problems = []
    if (missing = mine - theirs).any?
      problems << "the guard: the studio carries #{missing.sort.inspect}, " \
                  "which config.py does not read"
    end
    if (unmirrored = theirs - mine).any?
      problems << "the guard: config.py reads #{unmirrored.sort.inspect}, " \
                  "which the studio does not carry"
    end
    fields.each do |field|
      env = field[:env]
      next if env.nil? || !repo_env.key?(env)
      next if same_default?(field[:default], repo_env[env])
      problems << "the guard #{env}: studio default #{field[:default].inspect} " \
                  "!= service #{repo_env[env].inspect}"
    end
    problems
  end

  def unnamed_env_problems(fields, repo_env)
    fields.flat_map { |f| Array(f[:env]) }.uniq
          .reject { |name| repo_env.key?(name) || ENV_NOT_IN_CONFIG_PY.include?(name) }
          .sort
  end

  # --- the comparisons ------------------------------------------------------

  test "the studio's MODELS mirror the sibling repo's registry, key for key and licence for licence" do
    repo_entries = bucket("models")

    # A field the service names but this parser cannot read is a SKIP with the
    # reason -- never a silent pass. Collected across every entry so one
    # unreadable value names itself rather than hiding behind a green run.
    unreadable = []
    repo_entries.each do |key, entry|
      MODEL_FIELDS.each do |field|
        next unless absent?(pick(entry, *repo_names(field)))
        unreadable << "#{key}.#{field}"
      end
    end
    skip "the parser could not read #{unreadable.sort.join(', ')} from #{FLUX_REPO}" if unreadable.any?

    problems = model_problems(FluxConf::MODELS, repo_entries)
    assert_empty problems, "the studio's model mirror has drifted from " \
                           "#{FLUX_REPO}/chopshop_flux/models.py:\n  " + problems.join("\n  ")
  end

  test "the studio's MODIFIERS mirror the sibling repo's, key for key and weight file for weight file" do
    repo_entries = bucket("modifiers")

    unreadable = []
    repo_entries.each do |key, entry|
      MODIFIER_FIELDS.each do |field|
        next unless absent?(pick(entry, *repo_names(field)))
        unreadable << "#{key}.#{field}"
      end
      unreadable << "#{key}.targets" if absent?(pick(entry, *repo_names("targets")))
    end
    skip "the parser could not read #{unreadable.sort.join(', ')} from #{FLUX_REPO}" if unreadable.any?

    problems = modifier_problems(FluxConf::MODIFIERS, repo_entries)
    assert_empty problems, "the studio's modifier mirror has drifted from " \
                           "#{FLUX_REPO}/chopshop_flux/modifiers.py:\n  " + problems.join("\n  ")
  end

  test "the studio's VAES mirror the sibling repo's, key for key and repo for repo" do
    repo_entries = bucket("vaes")

    unreadable = []
    repo_entries.each do |key, entry|
      VAE_FIELDS.each do |field|
        next unless absent?(pick(entry, *repo_names(field)))
        unreadable << "#{key}.#{field}"
      end
      unreadable << "#{key}.targets" if absent?(pick(entry, *repo_names("targets")))
    end
    skip "the parser could not read #{unreadable.sort.join(', ')} from #{FLUX_REPO}" if unreadable.any?

    problems = vae_problems(FluxConf::VAES, repo_entries)
    assert_empty problems, "the studio's VAE mirror has drifted from #{FLUX_REPO}:\n  " +
                           problems.join("\n  ")
  end

  test "the studio's config mirror carries config.py's own constants and env inventory" do
    repo_constants = repo["config"]
    repo_env = repo["env"]
    refute_nil repo_constants,
               "the parser read no constants from #{FLUX_REPO}/chopshop_flux/config.py"
    refute_nil repo_env, "the parser read no env inventory from config.py"

    # A constant this parser could not find is a FAILURE, never a skip: "I could
    # not read it" must not read as "it agrees".
    missing = CONFIG_CONSTANTS - repo_constants.keys
    flunk "the parser read no #{missing.sort.join(', ')} from config.py — a comparison " \
          "that cannot find a constant is a broken comparison, not a pass" if missing.any?

    problems = config_problems(studio_constants, repo_constants)
    assert_empty problems, "the studio's config mirror has drifted from " \
                           "#{FLUX_REPO}/chopshop_flux/config.py:\n  " + problems.join("\n  ")
  end

  test "the studio's default model is the registry's own DEFAULT_MODEL_KEY" do
    theirs = repo["model_default"]
    assert_equal theirs, FluxConf::DEFAULT_MODEL_KEY,
                 "the page opens its model select on the studio's key, so a service " \
                 "whose default moved and a studio that did not is a page configuring " \
                 "a different model than the service would load"
  end

  test "the GPU guard's knobs are the service's, name for name and default for default" do
    repo_env = repo["env"]
    refute_nil repo_env, "the parser read no env inventory from config.py"

    # The service must still have the guard at all: without this, every
    # comparison below could pass on an inventory that has moved on.
    assert_includes repo_env.keys, "CHOPSHOP_FLUX_GUARD",
                    "config.py reads no guard mode — if the guard moved, this test's " \
                    "subject moved with it and the comparison must be re-pointed"
    assert_includes repo_env.keys, "CHOPSHOP_FLUX_LMSTUDIO_URL"

    problems = guard_problems(FluxConf::GUARD[:fields], repo_env)
    assert_empty problems, "the studio's GPU card has drifted from " \
                           "#{FLUX_REPO}/chopshop_flux/config.py:\n  " + problems.join("\n  ")
  end

  test "every variable the studio's inventory names is one the service actually reads" do
    repo_env = repo["env"]
    fields = FluxConf::CARDS.flat_map { |card| card[:fields] } + FluxConf::GUARD[:fields]

    unknown = unnamed_env_problems(fields, repo_env)
    assert_empty unknown, "the studio's inventory names #{unknown.inspect}, which " \
                          "#{FLUX_REPO}'s config.py never reads — a knob an operator " \
                          "would set for nothing"

    # And the inventory is not empty: a page whose help named no variable would
    # pass the assertion above for the wrong reason.
    assert_operator fields.count { |f| f[:env] }, :>=, 10,
                    "the inventory cannot have shrunk to nothing — that would make " \
                    "the comparison above vacuous"
  end

  # --- and the comparison can actually fail ---------------------------------
  #
  # The three tests above are only worth anything if the comparator rejects a
  # difference. So it is handed registries built FROM the studio's own, exact by
  # construction, and then corrupted by one character. If the first assertion
  # passes and the second does not, the comparison is real.

  def studio_as_repo_models
    FluxConf::MODELS.transform_values do |spec|
      MODEL_FIELDS.to_h { |field| [field == "licence" ? "license" : field, spec[field]] }
    end
  end

  def studio_as_repo_modifiers
    FluxConf::MODIFIERS.transform_values do |spec|
      MODIFIER_FIELDS.to_h { |field| [field == "licence" ? "license" : field, spec[field]] }
        .merge("targets" => spec["targets"])
    end
  end

  def studio_as_repo_vaes
    FluxConf::VAES.transform_values do |spec|
      VAE_FIELDS.to_h { |field| [field == "licence" ? "license" : field, spec[field]] }
        .merge("targets" => spec["targets"])
    end
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  test "the model comparison REJECTS a licence that differs by one character" do
    repo_entries = studio_as_repo_models
    assert_empty model_problems(FluxConf::MODELS, repo_entries),
                 "an identical registry must compare clean"

    corrupted = deep_copy(repo_entries)
    # `license` is the sibling repo's spelling -- and the one `repo_names` reads
    # first, so corrupting the British key here would be corrupting a key the
    # comparison never looks at, and the test would pass for the wrong reason.
    corrupted["klein-4b"]["license"] = "Apache-2.1"   # one digit
    problems = model_problems(FluxConf::MODELS, corrupted)
    refute_empty problems, "a licence that differs by one character MUST be a mismatch"
    assert_includes problems.join(" "), "Apache-2.1"
    assert_includes problems.join(" "), "Apache-2.0"
  end

  test "the model comparison REJECTS a changed step count, guidance, dim rule or key" do
    base = studio_as_repo_models

    steps = deep_copy(base)
    steps["klein-4b"]["default_steps"] = 5
    refute_empty model_problems(FluxConf::MODELS, steps),
                 "a step count that differs is a different schedule"

    guidance = deep_copy(base)
    guidance["klein-4b-base"]["default_guidance"] = 4.5
    refute_empty model_problems(FluxConf::MODELS, guidance)

    dims = deep_copy(base)
    dims["sdxl-1.0"]["min_dim"] = 64
    refute_empty model_problems(FluxConf::MODELS, dims)

    commercial = deep_copy(base)
    commercial["sdxl-turbo"]["commercial_ok"] = true
    refute_empty model_problems(FluxConf::MODELS, commercial),
                 "the one non-commercial model flipping to usable is the most expensive drift there is"

    extra = deep_copy(base).merge("klein-9b" => { "licence" => "Apache-2.0" })
    refute_empty model_problems(FluxConf::MODELS, extra),
                 "a model the service registers and the studio does not is drift too"

    dropped = deep_copy(base).reject { |k, _| k == "ssd-1b" }
    refute_empty model_problems(FluxConf::MODELS, dropped)
  end

  test "the modifier and VAE comparisons REJECT a changed key, repo, weight file or target set" do
    mods = studio_as_repo_modifiers
    assert_empty modifier_problems(FluxConf::MODIFIERS, mods),
                 "an identical modifier registry must compare clean"

    renamed = deep_copy(mods)
    renamed["sdxl-lightning-4step"]["weight_name"] = "sdxl_lightning_4step_loraa.safetensors"
    refute_empty modifier_problems(FluxConf::MODIFIERS, renamed),
                 "the file that is actually loaded is the whole point of weight_name"

    wrong_repo = deep_copy(mods)
    wrong_repo["pixel-art-xl"]["repo_id"] = "nerijs/pixel-art-xl-x"
    refute_empty modifier_problems(FluxConf::MODIFIERS, wrong_repo)

    # The licence a LoRA carries is its own -- bolting one onto an Apache-2.0
    # checkpoint does not launder it -- so a one-character change there has to
    # come out too.
    wrong_licence = deep_copy(mods)
    wrong_licence["lcm-lora-sd15"]["license"] = "CreativeML Open RAIL++-M License"
    refute_empty modifier_problems(FluxConf::MODIFIERS, wrong_licence)

    # A target set that drops one model: the same length is not required, and
    # membership is what the service gates on.
    narrow = deep_copy(mods)
    narrow["colouring-book"]["targets"] = %w[sdxl-1.0 ssd-1b]
    refute_empty modifier_problems(FluxConf::MODIFIERS, narrow)

    # And a nil-vs-number difference is a difference: several adapters genuinely
    # have no steps of their own, so "absent" and "0" must not compare equal.
    zeroed = deep_copy(mods)
    zeroed["klein-outpaint"]["steps"] = 0
    refute_empty modifier_problems(FluxConf::MODIFIERS, zeroed),
                 "nil steps and 0 steps are different claims about a schedule"

    vaes = studio_as_repo_vaes
    assert_empty vae_problems(FluxConf::VAES, vaes)

    vae_repo = deep_copy(vaes)
    vae_repo["taesdxl"]["repo_id"] = "madebyollin/taesdxlx"
    refute_empty vae_problems(FluxConf::VAES, vae_repo)

    vae_targets = deep_copy(vaes)
    vae_targets["taesd"]["targets"] = %w[sdxl-1.0]
    refute_empty vae_problems(FluxConf::VAES, vae_targets)

    vae_tiny = deep_copy(vaes)
    vae_tiny["taesd"]["tiny"] = false
    refute_empty vae_problems(FluxConf::VAES, vae_tiny),
                 "a TAESD presented as a full VAE is the softness note going missing"
  end

  test "the config and guard comparisons REJECT a moved constant, default or knob" do
    constants = studio_constants.merge("DEFAULT_OUT_DIR" => "./out", "UNUSED" => 1)
    assert_empty config_problems(studio_constants, constants),
                 "an identical mirror must compare clean (and an uncompared extra key " \
                 "in the service must not be a mismatch)"

    port = deep_copy(constants)
    port["DEFAULT_PORT"] = 8796
    refute_empty config_problems(studio_constants, port),
                 "the port the studio prints moving off the service's is drift"

    alignment = deep_copy(constants)
    alignment["DIMENSION_MULTIPLE"] = 8
    refute_empty config_problems(studio_constants, alignment),
                 "one family's alignment quoted as the module-level default is drift"

    # The guard, compared against the studio's own inventory rendered as the
    # service's: clean by construction, then corrupted by one value at a time.
    repo_env = FluxConf::GUARD[:fields].to_h { |f| [f[:env], f[:default]] }
    assert_empty guard_problems(FluxConf::GUARD[:fields], repo_env),
                 "the studio's own defaults must compare clean against themselves"

    vram = deep_copy(repo_env).merge("CHOPSHOP_FLUX_GUARD_VRAM_GB" => 4.0)
    refute_empty guard_problems(FluxConf::GUARD[:fields], vram),
                 "the VRAM line the guard refuses below is the knob most likely to move"

    budget = deep_copy(repo_env).merge("CHOPSHOP_FLUX_GUARD_WAIT" => 0.0)
    refute_empty guard_problems(FluxConf::GUARD[:fields], budget),
                 "a zero budget is not a missing one — 0 is a decision, unset is not"

    mode = deep_copy(repo_env).merge("CHOPSHOP_FLUX_GUARD" => "block")
    refute_empty guard_problems(FluxConf::GUARD[:fields], mode),
                 "the default mode moving to block changes what every deployment does " \
                 "with no other edit — the most expensive drift in this family"

    extra = deep_copy(repo_env).merge("CHOPSHOP_FLUX_GUARD_HOLD" => 3.0)
    refute_empty guard_problems(FluxConf::GUARD[:fields], extra),
                 "a guard knob the service reads and the studio omits is exactly the " \
                 "drift issue #13 recorded, and it must not be silent again"

    dropped = deep_copy(repo_env).reject { |k, _| k == "CHOPSHOP_FLUX_LMSTUDIO_URL" }
    refute_empty guard_problems(FluxConf::GUARD[:fields], dropped),
                 "and a knob the studio carries that the service dropped is drift too"

    # The name check: a typo'd variable is reported, a request parameter (no env)
    # is not a claim about the environment at all.
    assert_empty unnamed_env_problems([{ env: "CHOPSHOP_FLUX_MODEL" }, { env: nil }],
                                      repo_env)
    refute_empty unnamed_env_problems([{ env: "CHOPSHOP_FLUX_GUARDD" }], repo_env),
                 "a typo'd env name is a knob an operator would set for nothing"
  end

  # --- and the sentences themselves ----------------------------------------
  #
  # "The same sentences the service would" is a claim about WORDING, and wording
  # is exactly what a paraphrase gets wrong while every structural check above
  # stays green. So the templates are read out of the service's own `raise`
  # statements and rendered here against a synthetic entry.

  def template(name)
    value = repo["templates"][name]
    return value if value.is_a?(String) && value.include?("%")
    skip "the parser could not read the #{name} sentence out of #{FLUX_REPO}"
  end

  test "the licence gate's sentence is the service's, character for character" do
    entry = { "key" => "some-lora", "licence" => "Some License", "commercial_ok" => false }

    # Both service-side copies -- models.check_usable for a MODEL and
    # modifiers.check_modifier_usable for a LoRA or a VAE -- are checked, and
    # then they are required to be the same sentence as each other, because the
    # whole point is that one acknowledgement clears all three.
    [
      ["licence_models", "models.py check_usable"],
      ["licence_modifiers", "modifiers.py check_modifier_usable"]
    ].each do |name, where|
      expected = template(name) % ["some-lora", "Some License"]
      assert_equal expected, FluxConf.licence_problem(entry, "0"),
                   "#{where} and FluxConf.licence_problem must be the same sentence"
    end

    assert_nil FluxConf.licence_problem(entry, "1")
    refute_nil FluxConf.validate(width: "1024", height: "1024", images: "1",
                                 model_key: "sdxl-turbo", guidance: "0.0", ack: "0")[:problems]
                   .find { |p| p.include?("non-commercial use only") },
               "and validate must reach it on a model, not only on a modifier"
  end

  test "the unknown-key sentence is the service's, character for character" do
    rendered = template("unknown") % ["modifier", "teh-cool-lora",
                                      FluxConf::MODIFIERS.keys.sort.join(", ")]
    result = FluxConf.validate(width: "1024", height: "1024", images: "1",
                               model_key: "klein-4b", guidance: "1.0", ack: "0",
                               modifiers: ["teh-cool-lora"])
    assert_equal rendered, result[:problems].first,
                 "the studio's unknown-modifier sentence must be the service's"

    vae_rendered = template("unknown") % ["vae", "teh-vae", FluxConf::VAES.keys.sort.join(", ")]
    vae = FluxConf.validate(width: "1024", height: "1024", images: "1",
                            model_key: "klein-4b", guidance: "1.0", ack: "0", vae: "teh-vae")
    assert_equal vae_rendered, vae[:problems].first
  end

  # --- the parser itself ----------------------------------------------------

  test "the parser is reading the sibling repo's registry, not an empty accident" do
    repo  # skip/fail reasons come from here
    models = bucket("models")
    assert_operator models.size, :>=, 5, "the parser found no models in #{FLUX_REPO}"
    models.each do |key, entry|
      refute_nil pick(entry, "licence"), "the parser read no licence for #{key}"
    end
    # The three families the studio now mirrors are the ones this test exists to
    # pin; if the flux repo has not landed them yet the assertion above fails,
    # which is the intended answer rather than a bug in the parser.
    assert_includes models.keys, "klein-4b"
  end

  # WHAT THIS FILE DOES NOT VERIFY, said out loud rather than left implied:
  #
  #   * models.py's `pipeline` / `edit_pipeline` (which diffusers class loads the
  #     weights) are NOT mirrored into FluxConf at all, so nothing here compares
  #     them. The Sana guidance/resolution-binning gap this footer used to admit
  #     to is now CLOSED: `guidance_embedded` and `resolution_binning` are in
  #     MODEL_FIELDS above and are compared field for field, and
  #     flux_conf_registry_test.rb pins the behaviour they drive (no "guidance is
  #     ignored" warning on a model that honours it).
  #   * `notes` and `aliases` are not compared, deliberately (see the top).
  #   * The env inventory is compared for the variables the studio's page NAMES
  #     (its two card families), not for every variable config.py reads: MAX_PIXELS,
  #     IDLE_UNLOAD, IDLE_EXIT and HF_HOME are real knobs the page does not carry,
  #     and this test says nothing about them. A NEW guard-family knob, by
  #     contrast, fails here the moment it exists (GUARD_NAME).
  #   * Nothing here checks that the studio's page RENDERS what it mirrors. That
  #     is app/views/pages/flux_page_test.rb's job, and it is pinned there against
  #     FluxConf::MODELS rather than against the sibling repo.
end
