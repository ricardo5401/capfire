# frozen_string_literal: true

# Page/per_page semantics shared across listing endpoints.
#
# Why a concern (not a method on each controller):
#   /deploys#index, /tasks#index and any future listing want EXACTLY the
#   same pagination contract — same defaults, same caps, same response
#   shape. Duplicating the parse + count + slice + meta-build logic
#   across controllers is the kind of drift that ends in "deploys uses
#   per_page=25 by default but tasks uses 20" three months from now.
#
# Backwards compatibility with the legacy `?limit=N`:
#   The previous API exposed only `?limit=N` ("give me the last N rows").
#   Conceptually that's `page=1` with a custom `per_page=N`, so we honor
#   the param as an alias for `per_page` when `per_page` itself is
#   missing. New clients use `?page=` and `?per_page=`; old curl scripts
#   keep working unchanged.
#
# Response shape (consumers can rely on these keys):
#
#     {
#       "deploys": [ ... ],
#       "scope": "mine",
#       "pagination": {
#         "page": 3,
#         "per_page": 20,
#         "total_count": 247,
#         "total_pages": 13
#       }
#     }
#
# `total_pages` is computed even when `total_count` is zero (returns 1)
# so the client never has to special-case the empty-list case to render
# its "page X of Y" footer.
module Paginatable
  extend ActiveSupport::Concern

  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100

  private

  # Parses `?page` and `?per_page` from `params`, normalising both to
  # integers within sane bounds. Returns a frozen hash so callers can't
  # accidentally mutate it before computing the offset.
  #
  # Resolution rules:
  #   - page < 1 or non-numeric -> 1
  #   - per_page out of [1, MAX_PER_PAGE] -> clamped to that range
  #   - per_page missing AND legacy `limit` present -> use limit
  #   - per_page missing AND no legacy limit -> DEFAULT_PER_PAGE
  def pagination_params
    page = parse_positive_int(params[:page], default: 1)
    per_page = resolve_per_page
    { page: page, per_page: per_page }.freeze
  end

  # Applies pagination to an ActiveRecord scope. Returns a tuple
  # `[paginated_scope, meta]` so the caller can ALSO add other filters
  # before serialising — `paginated_scope.map(&:as_status_json)` works
  # straight away, and `meta` is ready to merge into the response body.
  #
  # The COUNT(*) is issued against the SAME scope right before the slice
  # so any `.where(...)` chained earlier is reflected in `total_count`.
  # Performance: even at tens of thousands of rows this is a single
  # indexed scan that returns in ~ms; we'd revisit if usage ever
  # justified a cursor-based scheme.
  def paginate(scope, page:, per_page:)
    total_count = scope.count
    total_pages = total_count.zero? ? 1 : ((total_count + per_page - 1) / per_page)

    # Out-of-range page numbers are tolerated rather than rejected: the
    # client just gets an empty list with the correct metadata, which is
    # what every reasonable UI wants ("next page is empty -> hide the
    # next button"). Throwing 400 here would force every consumer to
    # special-case the boundary.
    offset = (page - 1) * per_page
    paginated = scope.offset(offset).limit(per_page)

    meta = {
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages
    }

    [ paginated, meta ]
  end

  # Honors `?per_page` first, falls back to legacy `?limit`, then to the
  # module default. The clamp lives here (not in `paginate`) so a
  # malicious caller can't try to OOM the box with `?per_page=999999`.
  def resolve_per_page
    raw = params[:per_page].presence || params[:limit].presence
    parse_positive_int(raw, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  # Parses a positive integer with a default and an optional ceiling.
  # Treats anything <= 0, blank, or non-numeric as "use the default" —
  # consistent with how the legacy parse_limit behaved, so existing
  # clients see no surprise changes.
  def parse_positive_int(raw, default:, max: nil)
    return default if raw.blank?

    value = raw.to_i
    return default if value <= 0

    max ? [ value, max ].min : value
  end
end
