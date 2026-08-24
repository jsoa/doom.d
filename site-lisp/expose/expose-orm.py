"""What a Django QuerySet will ask the database for, without asking it.

Read by `expose-orm.el' and executed inside the project's own environment
(`manage.py shell' reads a script on stdin), so Django is already set up by
the time this runs. The expression to inspect arrives as JSON in
EXPOSE_ORM_PAYLOAD rather than interpolated into the source, which keeps
quoting out of it entirely.

By default nothing here opens a database connection. `str(queryset.query)'
compiles SQL through the backend's operations without connecting, and every
fact reported below comes from the query object or the model's `_meta' -- so
the default path is safe to point at a project whose DB_HOST is production,
or whose database isn't running at all.

Asking for a plan (`explain' in the payload) is the exception, and the only
thing here that connects: EXPLAIN needs the planner's own statistics, and
EXPLAIN ANALYZE additionally *runs the query*. Both go through
`fetch_plan', which rolls its transaction back and sets a statement timeout
regardless.
"""

import ast
import importlib
import json
import os

BEGIN = "<<<EXPOSE-ORM-BEGIN>>>"
END = "<<<EXPOSE-ORM-END>>>"

# Method calls that write. The expression is *evaluated* to build the
# queryset, so a selection that reaches one line too far and includes
# `.delete()' would destroy data for real. Refused before anything is
# evaluated.
MUTATING_METHODS = {
    "delete", "adelete", "update", "aupdate", "create", "acreate",
    "get_or_create", "aget_or_create", "update_or_create", "aupdate_or_create",
    "bulk_create", "abulk_create", "bulk_update", "abulk_update", "save",
    "asave", "add", "remove", "clear", "set",
}

# Method calls that run the query. Not destructive, but they open the
# connection this is specifically meant not to need -- against a remote or
# production database that is not a free action.
#
# `all()' is deliberately absent: it is the most common call in any queryset
# expression and is entirely lazy. Banning it by name would reject
# `Event.objects.all()' outright.
EVALUATING_METHODS = {
    "get", "aget", "first", "afirst", "last", "alast", "count", "acount",
    "exists", "aexists", "aggregate", "aaggregate", "earliest", "aearliest",
    "latest", "alatest", "in_bulk", "ain_bulk", "iterator", "aiterator",
    "explain", "aexplain",
}

# Builtins that consume the queryset, which is what actually runs it. These
# are only ever plain names -- `qs.set(...)' is a related-manager write and
# is caught above, while `set(qs)' is an evaluation, so the two must be told
# apart by call form rather than by name.
EVALUATING_BUILTINS = {
    "list", "tuple", "set", "dict", "frozenset", "len", "sorted", "sum",
    "any", "all", "bool", "min", "max", "next", "iter", "reversed",
}

# Raw SQL is neither analysable nor safely assumed read-only.
OPAQUE = {"raw", "execute", "executemany"}

# Lookups that a plain B-tree index cannot serve, however well indexed the
# column is: they compile to LIKE with a leading wildcard, or to a function
# applied to the column.
UNINDEXABLE_LOOKUPS = {
    "contains", "icontains", "iexact", "endswith", "iendswith",
    "regex", "iregex", "istartswith", "search", "trigram_similar",
}


def refusal(tree):
    """Return why TREE must not be evaluated, or None if it is safe.

    Takes an already-parsed tree, not a source string, so the same check
    applies identically before and after `rewrite_terminal_call' -- a
    `.get()`/`.exists()`/etc. at the *top* of the expression is handled by
    rewriting it away entirely (see there), but one buried inside, say, a
    filter argument (`qs.filter(pk=Other.objects.get(x=1).id)`) still
    reaches here and is still refused: rewriting only the outermost call
    is a deliberate, much narrower fix than trying to safely evaluate an
    expression with a real side effect nested inside it."""

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue

        if isinstance(node.func, ast.Attribute):
            name = node.func.attr

            if name in MUTATING_METHODS:
                return (
                    "`.%s()' writes to the database. Evaluating the selection "
                    "would run it for real, so nothing was executed." % name
                )
            if name in EVALUATING_METHODS:
                return (
                    "`.%s()' would execute the query. This inspects a queryset "
                    "without connecting -- drop the call and select the "
                    "queryset itself." % name
                )
            if name in OPAQUE:
                return "`.%s()' runs SQL that cannot be inspected this way." % name

        elif isinstance(node.func, ast.Name):
            name = node.func.id

            if name in EVALUATING_BUILTINS:
                return (
                    "`%s()' consumes the queryset, which runs it. Select the "
                    "queryset itself instead." % name
                )

    return None


# Terminal methods rewritten rather than refused: each is a filter chain
# plus a single-row/aggregate read, and the read is the only part of it
# that would actually connect. The filter chain underneath is exactly
# what `.query' can already show without connecting -- so the call is
# dropped (or, for `.get()', turned back into the `.filter()' it already
# is under the hood: `QuerySet.get()' is `self.filter(*args, **kwargs)'
# followed by a single-row check, not a different query) rather than
# evaluated. Maps each method to what its rewrite loses, for the note
# shown alongside the result.
REWRITABLE_TERMINALS = {
    "get": ("filter", "the single-row check `.get()` adds"),
    "aget": ("filter", "the single-row check `.aget()` adds"),
    "exists": (None, "the `SELECT (1) ... LIMIT 1` wrapper `.exists()` actually runs"),
    "aexists": (None, "the `SELECT (1) ... LIMIT 1` wrapper `.aexists()` actually runs"),
    "first": (None, "the ordering/`LIMIT 1` `.first()` adds"),
    "afirst": (None, "the ordering/`LIMIT 1` `.afirst()` adds"),
    "last": (None, "the reversed ordering/`LIMIT 1` `.last()` adds"),
    "alast": (None, "the reversed ordering/`LIMIT 1` `.alast()` adds"),
    "count": (None, "the `SELECT COUNT(*)` wrapper `.count()` actually runs"),
    "acount": (None, "the `SELECT COUNT(*)` wrapper `.acount()` actually runs"),
    "earliest": (None, "the ordering/`LIMIT 1` `.earliest()` adds"),
    "aearliest": (None, "the ordering/`LIMIT 1` `.aearliest()` adds"),
    "latest": (None, "the ordering/`LIMIT 1` `.latest()` adds"),
    "alatest": (None, "the ordering/`LIMIT 1` `.latest()` adds"),
}


def rewrite_terminal_call(tree):
    """Return (TREE, NOTE): TREE with its outermost call rewritten away if
    it is one of `REWRITABLE_TERMINALS', unchanged otherwise; NOTE
    explains what changed, or is None if nothing did.

    Only the *outermost* call -- what the whole expression evaluates to.
    A `.get()' nested inside, building an argument for something else,
    is a different and harder problem (see `refusal') this does not
    attempt."""

    call = tree.body
    if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Attribute):
        return tree, None

    name = call.func.attr
    if name not in REWRITABLE_TERMINALS:
        return tree, None

    replacement, lost = REWRITABLE_TERMINALS[name]

    if replacement:
        body = ast.Call(
            func=ast.Attribute(value=call.func.value, attr=replacement, ctx=ast.Load()),
            args=call.args,
            keywords=call.keywords,
        )
    else:
        body = call.func.value

    new_tree = ast.Expression(body=body)
    ast.fix_missing_locations(new_tree)

    note = "`.%s()` was not run; shown is the SQL for the underlying selection, without %s." % (
        name,
        lost,
    )
    return new_tree, note


def build_namespace(module_path):
    """Return (namespace, note) for evaluating the expression.

    Every model is bound by its own name, so an expression that names only a
    model works from anywhere. The defining module is layered on top when it
    imports, which brings along whatever aliases and helpers the file itself
    uses -- and is the only way a locally-defined name resolves at all.
    """

    from django.apps import apps

    namespace = {}
    for model in apps.get_models():
        namespace.setdefault(model.__name__, model)

    note = None
    if module_path:
        try:
            module = importlib.import_module(module_path)
        except Exception as exc:
            note = "could not import %s (%s); only model names are in scope" % (
                module_path,
                exc.__class__.__name__,
            )
        else:
            namespace.update(vars(module))

    return namespace, note


def index_status(field):
    """Return (INDEXED, EXPLANATION) for FIELD.

    A composite index only serves a column when that column leads it, which
    is the case people most often get wrong: a query filtering on the second
    column of a two-column index scans anyway.
    """

    meta = field.model._meta

    if field.primary_key:
        return True, "primary key"
    if field.unique:
        return True, "unique"
    if getattr(field, "db_index", False):
        return True, "db_index=True"

    for index in getattr(meta, "indexes", ()) or ():
        names = [name.lstrip("-") for name in (index.fields or ())]
        if not names:
            continue
        label = index.name or ", ".join(names)
        if names[0] == field.name:
            return True, "leads index (%s)" % label
        if field.name in names:
            return False, "only a non-leading column of index (%s)" % label

    for together in getattr(meta, "unique_together", ()) or ():
        if not together:
            continue
        if together[0] == field.name:
            return True, "leads unique_together %s" % (tuple(together),)
        if field.name in together:
            return False, "only a non-leading column of unique_together %s" % (
                tuple(together),
            )

    return False, "no index"


def collect_conditions(node, found):
    """Walk a WhereNode, collecting the (field, lookup) pairs it tests."""

    for child in getattr(node, "children", ()) or ():
        lhs = getattr(child, "lhs", None)
        target = getattr(lhs, "target", None)

        if target is not None:
            found.append((target, getattr(child, "lookup_name", None)))
        else:
            collect_conditions(child, found)


def describe_filters(query):
    conditions = []
    collect_conditions(query.where, conditions)

    described = []
    for field, lookup in conditions:
        indexed, why = index_status(field)

        # An unindexable lookup makes the index question moot: the column
        # can be perfectly indexed and still be scanned.
        if lookup in UNINDEXABLE_LOOKUPS:
            indexed = False
            why = "`%s' cannot use a B-tree index" % lookup

        described.append(
            {
                "table": field.model._meta.db_table,
                "column": field.column,
                "lookup": lookup or "exact",
                "indexed": indexed,
                "why": why,
            }
        )

    return described


def describe_ordering(query):
    ordering = list(query.order_by or ())
    source = "order_by()"

    if not ordering:
        ordering = list(query.get_meta().ordering or ())
        source = "Meta.ordering"

    described = []
    for term in ordering:
        name = term.lstrip("-")
        entry = {"term": term, "source": source, "indexed": None, "why": None}

        # A traversal orders by a column on another table; whether that is
        # indexed is a question about that model, not this one.
        if "__" not in name and name != "?":
            try:
                field = query.get_meta().get_field(name)
            except Exception:
                pass
            else:
                entry["indexed"], entry["why"] = index_status(field)

        described.append(entry)

    return described


def describe_joins(query):
    joins = []
    for alias, join in (query.alias_map or {}).items():
        join_type = getattr(join, "join_type", None)
        if not join_type:
            continue
        joins.append(
            {
                "table": getattr(join, "table_name", alias),
                "type": join_type,
                "nullable": bool(getattr(join, "nullable", False)),
            }
        )
    return joins


def compile_sql(queryset):
    from django.core.exceptions import EmptyResultSet

    try:
        sql = str(queryset.query)
    except EmptyResultSet:
        return None, "Django knows this matches nothing and will not query at all"
    except Exception as exc:
        return None, "could not compile: %s: %s" % (exc.__class__.__name__, exc)

    try:
        import sqlparse
    except ImportError:
        return sql, None

    return sqlparse.format(sql, reindent=True, keyword_case="upper"), None


def fetch_plan(queryset, payload):
    """Return (PLAN, ERROR) from the database for QUERYSET.

    ANALYZE genuinely executes the query, so it runs inside a transaction
    that is always rolled back and under a statement timeout. A SELECT has
    nothing to roll back, but the guard costs nothing and the alternative --
    a CTE with a write in it, or an expression that slipped past the parser
    -- is unrecoverable.
    """

    analyze = bool(payload.get("analyze"))
    timeout_ms = int(payload.get("timeout_ms") or 10000)
    dsn = payload.get("dsn")

    options = ["FORMAT JSON"]
    if analyze:
        options.extend(["ANALYZE", "BUFFERS"])
    prefix = "EXPLAIN (%s) " % ", ".join(options)

    try:
        sql, params = queryset.query.sql_with_params()
    except Exception as exc:
        return None, "could not compile SQL: %s: %s" % (exc.__class__.__name__, exc)

    # An explicit DSN exists so the plan can be taken from a database you
    # chose -- a replica or a dev copy -- rather than whichever one the
    # project's settings happen to point at.
    if dsn:
        try:
            import psycopg2
        except ImportError:
            try:
                import psycopg as psycopg2  # psycopg 3
            except ImportError:
                return None, "no psycopg available to use expose-orm-dsn"

        try:
            connection = psycopg2.connect(dsn)
        except Exception as exc:
            return None, "could not connect: %s: %s" % (exc.__class__.__name__, exc)

        try:
            with connection:
                with connection.cursor() as cursor:
                    cursor.execute("SET LOCAL statement_timeout = %s", (timeout_ms,))
                    cursor.execute(prefix + sql, params)
                    rows = cursor.fetchall()
            connection.rollback()
        except Exception as exc:
            return None, "%s: %s" % (exc.__class__.__name__, exc)
        finally:
            connection.close()

        return rows[0][0], None

    from django.db import connections, transaction

    alias = payload.get("database") or "default"
    if alias not in connections:
        return None, "no database named %r in settings" % alias

    connection = connections[alias]

    try:
        with transaction.atomic(using=alias):
            with connection.cursor() as cursor:
                cursor.execute("SET LOCAL statement_timeout = %s", (timeout_ms,))
                cursor.execute(prefix + sql, params)
                plan = cursor.fetchall()[0][0]
            # Always. Nothing here is meant to outlive the inspection.
            transaction.set_rollback(True, using=alias)
    except Exception as exc:
        return None, "%s: %s" % (exc.__class__.__name__, exc)

    return plan, None


def combine_notes(*notes):
    """Return NOTES joined into one string, dropping any that are None."""

    joined = [note for note in notes if note]
    return "; ".join(joined) if joined else None


# django.db.models.lookups' own names, not reconstructed: a lookup
# doesn't change what *field* a keyword argument targets, only how it's
# compared, so `created_at__gte` and `created_at__isnull` both target
# `created_at` -- the suffix just has to be recognised and peeled off to
# find it.
LOOKUP_SUFFIXES = {
    "exact", "iexact", "contains", "icontains", "in", "gt", "gte", "lt", "lte",
    "startswith", "istartswith", "endswith", "iendswith", "range", "date",
    "year", "iso_year", "month", "day", "week", "week_day", "quarter", "time",
    "hour", "minute", "second", "isnull", "regex", "iregex", "search",
    "trigram_similar",
}

# Only these actually take field-shaped keyword arguments worth mocking.
# `annotate()`/`aggregate()` keywords name the *output*, not a field, and
# `order_by()`/`values()' take positional field names as strings, not
# keywords -- none of that is what this is for.
LOOKUP_METHODS = {"filter", "afilter", "exclude", "aexclude", "get", "aget"}


def field_mock_value(field):
    """Return an AST literal for a plausible value of FIELD's own type.

    Django's `to_python'/`get_prep_value' generally accept a same-shaped
    string in place of a real `date'/`datetime'/`time'/`UUID' object --
    ISO 8601 for the first three, the standard hyphenated form for the
    last -- so a real one of those never has to be constructed here."""

    internal = field.get_internal_type() if field is not None else None

    integer_types = {
        "AutoField", "BigAutoField", "SmallAutoField", "IntegerField",
        "BigIntegerField", "SmallIntegerField", "PositiveIntegerField",
        "PositiveSmallIntegerField", "PositiveBigIntegerField",
        "ForeignKey", "OneToOneField", "ManyToManyField",
    }
    char_types = {
        "CharField", "TextField", "SlugField", "EmailField", "URLField",
        "GenericIPAddressField", "FilePathField", "FileField", "ImageField",
    }

    if internal in integer_types:
        return ast.Constant(value=1)
    if internal in char_types:
        return ast.Constant(value="x")
    if internal in ("FloatField", "DecimalField"):
        return ast.Constant(value=0)
    if internal in ("BooleanField", "NullBooleanField"):
        return ast.Constant(value=True)
    if internal == "DateField":
        return ast.Constant(value="2024-01-01")
    if internal == "DateTimeField":
        return ast.Constant(value="2024-01-01T00:00:00")
    if internal == "TimeField":
        return ast.Constant(value="00:00:00")
    if internal == "DurationField":
        return ast.Constant(value="0:00:00")
    if internal == "UUIDField":
        return ast.Constant(value="00000000-0000-0000-0000-000000000001")
    if internal == "JSONField":
        return ast.Dict(keys=[], values=[])
    if internal == "BinaryField":
        return ast.Constant(value=b"")

    # Unresolved field, or a type not listed above: an integer is the
    # single most likely to compile without a validation error of
    # anything that could be guessed blind (it is what a ForeignKey, by
    # far the most common miss, needs).
    return ast.Constant(value=1)


def field_mock(field, lookup):
    """Return an AST literal for FIELD, shaped for LOOKUP.

    `isnull' ignores the field's own type -- it is always a plain bool.
    `in'/`range' wrap the field's own mock the way those lookups need
    their argument shaped, rather than mocking a list/tuple directly,
    so e.g. an `in' lookup on a ForeignKey still gets a list of a
    plausible *pk*, not a list of something else."""

    if lookup == "isnull":
        return ast.Constant(value=True)

    base = field_mock_value(field)

    if lookup == "in":
        return ast.List(elts=[base], ctx=ast.Load())
    if lookup == "range":
        return ast.Tuple(elts=[base, base], ctx=ast.Load())

    return base


def resolve_field(model, path):
    """Return (FIELD, LOOKUP) for dotted lookup PATH on MODEL.

    FIELD is None when MODEL is unknown or PATH does not resolve --
    field_mock_value's own fallback still applies, this just means it
    could not be more specific than that."""

    parts = path.split("__")

    lookup = None
    if len(parts) > 1 and parts[-1] in LOOKUP_SUFFIXES:
        lookup = parts.pop()

    field = None
    current_model = model
    for part in parts:
        if current_model is None:
            return None, lookup
        try:
            field = current_model._meta.get_field(part)
        except Exception:
            return None, lookup
        current_model = getattr(field, "related_model", None)

    return field, lookup


def mock_unresolvable_arguments(tree, namespace):
    """Return (TREE, MOCKED): TREE with unresolvable keyword-argument
    values in filter()/exclude()/get()/aget() calls replaced by a
    plausible value for the field being compared. MOCKED lists what was
    replaced and with what, for the result's note.

    Structural, not reactive: every keyword argument on every matching
    call is tried in isolation and only ever replaced *whole* -- never
    a bare name found buried somewhere inside a larger expression -- so
    `created_by=self.request.user` is mocked as one unit, the same way
    `created_by=request.user.pk` or `created_by=some_helper(request)`
    would be, without needing to know why evaluating it failed, only
    that it did.

    A post-order walk, children before parents: a chained
    `Model.objects.filter(a=X).filter(b=1)' needs the inner call's `a'
    mocked before the outer call evaluates that inner call to find out
    what model `b' belongs to -- otherwise the inner failure would
    still be unresolved at the moment the outer call's own model
    lookup tries to evaluate it."""

    mocked = []

    def visit(node):
        for child in ast.iter_child_nodes(node):
            visit(child)

        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
            return
        if node.func.attr not in LOOKUP_METHODS:
            return

        model = None
        try:
            base = eval(  # noqa: S307
                compile(ast.Expression(body=node.func.value), "<expose-orm>", "eval"),
                namespace,
            )
            model = getattr(base, "model", None)
        except Exception:
            model = None

        for keyword in node.keywords:
            if keyword.arg is None:  # a **kwargs spread -- nothing to resolve
                continue

            try:
                eval(  # noqa: S307
                    compile(ast.Expression(body=keyword.value), "<expose-orm>", "eval"),
                    namespace,
                )
            except Exception:
                pass
            else:
                continue  # already resolves fine -- leave it alone

            field, lookup = resolve_field(model, keyword.arg)
            original = ast.unparse(keyword.value)
            keyword.value = field_mock(field, lookup)
            ast.fix_missing_locations(keyword.value)

            mocked.append(
                "`%s=%s` mocked as `%s`%s"
                % (
                    keyword.arg,
                    original,
                    ast.unparse(keyword.value),
                    " (%s)" % field.get_internal_type() if field is not None else "",
                )
            )

    visit(tree.body)
    return tree, mocked


def analyse(expression, module_path, payload=None):
    from django.db.models import Manager, QuerySet

    try:
        tree = ast.parse(expression.strip(), mode="eval")
    except SyntaxError as exc:
        return {"error": "not a single Python expression: %s" % exc, "refused": True}

    tree, rewrite_note = rewrite_terminal_call(tree)

    blocked = refusal(tree)
    if blocked:
        return {"error": blocked, "refused": True}

    namespace, import_note = build_namespace(module_path)

    tree, mocked = mock_unresolvable_arguments(tree, namespace)
    mock_note = (
        "mocked, since the query's shape doesn't depend on the actual value: "
        + "; ".join(mocked)
        if mocked
        else None
    )

    note = combine_notes(import_note, rewrite_note, mock_note)

    try:
        value = eval(compile(tree, "<expose-orm>", "eval"), namespace)  # noqa: S307
    except NameError as exc:
        return {
            "error": "%s -- this expression depends on a name that only exists "
            "where it was written (a local, `self', or `request'). If it is the "
            "query's shape you want and not this particular value, replace it "
            "with a literal (`event=1` instead of `event=event`) and try "
            "again -- the SQL, indexes, and joins are the same either way; "
            "only the bound parameter differs." % exc,
            "note": note,
        }
    except Exception as exc:
        return {"error": "%s: %s" % (exc.__class__.__name__, exc), "note": note}

    # `Event.objects' is a manager, and is what you get by selecting the
    # start of a chain; treat it as the queryset it stands for.
    if isinstance(value, Manager):
        value = value.all()

    if not isinstance(value, QuerySet):
        return {
            "error": "that expression is a %s, not a queryset"
            % type(value).__name__,
            "note": note,
        }

    query = value.query
    sql, sql_note = compile_sql(value)

    result = {
        "model": "%s.%s" % (query.model._meta.app_label, query.model.__name__),
        "table": query.model._meta.db_table,
        "sql": sql,
        "sql_note": sql_note,
        "note": note,
        "filters": describe_filters(query),
        "ordering": describe_ordering(query),
        "joins": describe_joins(query),
        "select_related": bool(query.select_related),
        "select_related_fields": (
            sorted(query.select_related) if isinstance(query.select_related, dict) else []
        ),
        "prefetch_related": sorted(
            str(lookup) for lookup in (value._prefetch_related_lookups or ())
        ),
        "distinct": bool(query.distinct),
        "low_mark": query.low_mark,
        "high_mark": query.high_mark,
        "annotations": sorted((query.annotations or {}).keys()),
        "relations": sorted(
            field.name
            for field in query.model._meta.get_fields()
            if field.many_to_one or field.one_to_one
        ),
    }

    if (payload or {}).get("explain"):
        plan, plan_error = fetch_plan(value, payload)
        result["plan"] = plan
        result["plan_error"] = plan_error
        result["analyzed"] = bool(payload.get("analyze"))

    return result


def main():
    payload = json.loads(os.environ.get("EXPOSE_ORM_PAYLOAD", "{}"))

    try:
        result = analyse(
            payload.get("expression", ""), payload.get("module"), payload
        )
    except Exception as exc:  # noqa: BLE001 - reported, never swallowed
        import traceback

        result = {
            "error": "%s: %s" % (exc.__class__.__name__, exc),
            "traceback": traceback.format_exc(),
        }

    print(BEGIN)
    print(json.dumps(result))
    print(END)


main()
