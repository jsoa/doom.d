"""What a Django QuerySet will ask the database for, without asking it.

Read by `expose-orm.el' and executed inside the project's own environment
(`manage.py shell' reads a script on stdin), so Django is already set up by
the time this runs. The expression to inspect arrives as JSON in
EXPOSE_ORM_PAYLOAD rather than interpolated into the source, which keeps
quoting out of it entirely.

Nothing here opens a database connection. `str(queryset.query)' compiles SQL
through the backend's operations without connecting, and every fact reported
below comes from the query object or the model's `_meta' -- so this is safe
to point at a project whose DB_HOST is production, or whose database isn't
running at all.
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


def refusal(expression):
    """Return why EXPRESSION must not be evaluated, or None if it is safe."""

    try:
        tree = ast.parse(expression.strip(), mode="eval")
    except SyntaxError as exc:
        return "not a single Python expression: %s" % exc

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


def analyse(expression, module_path):
    from django.db.models import Manager, QuerySet

    blocked = refusal(expression)
    if blocked:
        return {"error": blocked, "refused": True}

    namespace, note = build_namespace(module_path)

    try:
        value = eval(expression.strip(), namespace)  # noqa: S307
    except NameError as exc:
        return {
            "error": "%s -- this expression depends on a name that only exists "
            "where it was written (a local, `self', or `request')." % exc,
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

    return {
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


def main():
    payload = json.loads(os.environ.get("EXPOSE_ORM_PAYLOAD", "{}"))

    try:
        result = analyse(payload.get("expression", ""), payload.get("module"))
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
