/**
 * Flat-to-tree converter. The backend stores self-referential
 * rows (Route→parent Route via {@code idParent}) as a flat
 * list ordered by {@code menuOrder, id}, and the consumer
 * wants a tree. This util bridges those two.
 *
 * <p>Generic over {@code T} and the key accessors so it can
 * be reused for any future tree-shaped surface (e.g. if the
 * WriteDefinition hierarchy ever grows a parent FK, or if a
 * future {@code /getMenuByParent} tree endpoint replaces the
 * flat /myMenu response).
 *
 * <p>Legacy data quirk: the legacy {@code sso-service}
 * codebase stored {@code 0L} as a root sentinel. The
 * modernized backend normalises {@code 0 → null} on write
 * (RouteService.copy), but existing rows may still carry
 * {@code 0}. This util normalises both: any parent id that
 * is {@code null}, {@code undefined}, or {@code 0} (numeric
 * or string) is treated as a root, AND any parent id that
 * does not appear in the input list is also treated as a
 * root (defensive — orphans should never silently go
 * missing from the rendered tree).
 */
export interface TreeNode<T> {
  data: T;
  children: TreeNode<T>[];
}

/**
 * Options for {@link buildTree}. The two accessor
 * functions are required so the util stays free of any
 * hard-coded field names; {@code compare} is optional and
 * defaults to a numeric-stable sort on the ids.
 */
export interface BuildTreeOptions<T> {
  /** Returns the unique id of a row. Used as the map key
   *  AND as the {@code children} lookup key. */
  getId: (item: T) => number | string;
  /** Returns the parent id, or {@code null}/{@code undefined}
   *  for a root. The util also treats {@code 0} as a root
   *  for legacy-data compat. */
  getParentId: (item: T) => number | string | null | undefined;
  /** Optional sort comparator applied recursively at every
   *  level (parents first, then their children). Stable by
   *  parent sort (browsers sort stably per Array#sort). */
  compare?: (a: T, b: T) => number;
}

const isRootParent = (
  parentId: number | string | null | undefined,
): boolean => {
  if (parentId === null || parentId === undefined) return true;
  if (typeof parentId === "number" && parentId === 0) return true;
  if (typeof parentId === "string" && parentId === "0") return true;
  return false;
};

/**
 * Builds a forest (array of root trees) from a flat list.
 * Each level is sorted via {@code options.compare} before
 * recursing into the children.
 */
export function buildTree<T>(
  items: readonly T[],
  options: BuildTreeOptions<T>,
): TreeNode<T>[] {
  const { getId, getParentId, compare } = options;

  // Pass 1: register every row by id. Children assigned in
  // pass 2 so the map is fully populated and orphan parent
  // ids (rows pointing at a parent not in the list) are
  // detected — those rows go to the roots rather than
  // silently disappearing.
  const byId = new Map<number | string, TreeNode<T>>();
  for (const item of items) {
    byId.set(getId(item), { data: item, children: [] });
  }

  const roots: TreeNode<T>[] = [];
  for (const item of items) {
    const node = byId.get(getId(item));
    // node is always defined here because we just inserted
    // it, but the strict + noUncheckedIndexedAccess flags
    // on the project's tsconfig narrow this to TreeNode<T>
    // | undefined; defensive guard is the simpler shape.
    if (!node) continue;

    const parentId = getParentId(item);
    if (isRootParent(parentId) || !byId.has(parentId as number | string)) {
      roots.push(node);
    } else {
      const parent = byId.get(parentId as number | string);
      if (parent) parent.children.push(node);
    }
  }

  if (compare) {
    const sortLevel = (level: TreeNode<T>[]): void => {
      level.sort((a, b) => compare(a.data, b.data));
      for (const n of level) sortLevel(n.children);
    };
    sortLevel(roots);
  }

  return roots;
}
