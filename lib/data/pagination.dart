// lib/data/pagination.dart — bounded, explicit paging.
//
// A page request is validated rather than clamped into shape silently: negative
/// values are an error, an over-large limit is capped at the repository's
// maximum, and the resulting [Page] always says how many records exist in total
// so a caller can tell "no more" from "not loaded yet".
library;

import 'data_errors.dart';

/// The default number of records a page holds.
const int defaultPageLimit = 50;

/// The largest limit any repository will serve in one page unless it says
/// otherwise.
const int defaultMaxPageLimit = 500;

class PageRequest {
  /// Validates immediately: negative values are an error, an over-large limit is
  /// capped. The constructor is deliberately not `const`, because a const
  /// constructor could only assert — and asserts are compiled out of release
  /// builds, which is exactly where a bad limit would hurt.
  PageRequest({
    int offset = 0,
    int limit = defaultPageLimit,
    int maxLimit = defaultMaxPageLimit,
  }) : offset = _checkedOffset(offset),
       limit = _cappedLimit(limit, maxLimit);

  static int _checkedOffset(int offset) {
    if (offset < 0) {
      throw InvalidPageRequestError('offset must not be negative, got $offset');
    }
    return offset;
  }

  static int _cappedLimit(int limit, int maxLimit) {
    if (limit < 0) {
      throw InvalidPageRequestError('limit must not be negative, got $limit');
    }
    if (maxLimit < 0) {
      throw InvalidPageRequestError('maxLimit must not be negative');
    }
    return limit > maxLimit ? maxLimit : limit;
  }

  /// Reads better at call sites that pass a limit straight from a caller.
  factory PageRequest.validated({
    int offset = 0,
    int limit = defaultPageLimit,
    int maxLimit = defaultMaxPageLimit,
  }) {
    return PageRequest(offset: offset, limit: limit, maxLimit: maxLimit);
  }

  final int offset;
  final int limit;

  @override
  String toString() => 'PageRequest(offset: $offset, limit: $limit)';
}

/// One page of results plus the total number of matching records.
class Page<T> {
  Page({
    required List<T> items,
    required this.offset,
    required this.limit,
    required this.total,
  }) : items = List<T>.unmodifiable(items);

  /// An empty page for a request that matched nothing.
  factory Page.empty(PageRequest request) => Page<T>(
    items: const <Never>[],
    offset: request.offset,
    limit: request.limit,
    total: 0,
  );

  final List<T> items;
  final int offset;
  final int limit;

  /// How many records match in total, not just on this page.
  final int total;

  int get length => items.length;

  bool get isEmpty => items.isEmpty;

  bool get isNotEmpty => items.isNotEmpty;

  /// Whether another page after this one would hold records.
  bool get hasMore => offset + items.length < total;

  /// The request for the next page, or null when this is the last one.
  PageRequest? get nextPage => hasMore
      ? PageRequest.validated(offset: offset + items.length, limit: limit)
      : null;

  @override
  String toString() =>
      'Page(${items.length}/$total, offset: $offset, limit: $limit)';
}

/// Slices an already-ordered list into a [Page].
///
/// [total] overrides the count of readable records, which is what a listing that
/// skipped unreadable records needs: the total must still say how many records
/// exist.
Page<T> pageOf<T>(List<T> ordered, PageRequest request, {int? total}) {
  final start = request.offset > ordered.length
      ? ordered.length
      : request.offset;
  final end = start + request.limit > ordered.length
      ? ordered.length
      : start + request.limit;
  return Page<T>(
    items: ordered.sublist(start, end),
    offset: request.offset,
    limit: request.limit,
    total: total ?? ordered.length,
  );
}
