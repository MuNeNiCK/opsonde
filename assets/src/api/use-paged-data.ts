import { useCallback, useEffect, useRef, useState } from "react";

export type PageData<T> = { data: T[]; page: { next: string | null } };
type View<T, Page extends PageData<T>> = Page & {
  index: number;
  cursors: Array<string | undefined>;
};
type Position = { index: number; cursors: Array<string | undefined> };

export function usePagedData<T, Page extends PageData<T> = PageData<T>>(
  load: (after: string | undefined, signal: AbortSignal) => Promise<Page>,
) {
  const initial = {
    load,
    view: null as View<T, Page> | null,
    pending: true,
    error: null as unknown,
    attempt: { index: 0, cursors: [undefined] } as Position,
  };
  const [state, setState] = useState(initial);
  const current = state.load === load ? state : initial;
  const { view, pending, error, attempt } = current;
  const owner = useRef<AbortController | null>(null);
  const mounted = useRef(false);
  const request = useCallback(
    async (index: number, cursors: Array<string | undefined>) => {
      if (!mounted.current) return;
      owner.current?.abort();
      const controller = new AbortController();
      owner.current = controller;
      return load(cursors[index], controller.signal)
        .then((result) => {
          if (!controller.signal.aborted)
            setState({
              load,
              view: { ...result, index, cursors },
              pending: false,
              error: null,
              attempt: { index, cursors },
            });
        })
        .catch((cause) => {
          if (!controller.signal.aborted) {
            setState((previous) => ({
              load,
              view: previous.load === load ? previous.view : null,
              pending: false,
              error: cause,
              attempt: { index, cursors },
            }));
            throw cause;
          }
        });
    },
    [load],
  );
  useEffect(() => {
    mounted.current = true;
    void request(0, [undefined]).catch(() => {});
    return () => {
      mounted.current = false;
      owner.current?.abort();
    };
  }, [request]);
  function start(index: number, cursors: Array<string | undefined>) {
    if (!mounted.current) return Promise.resolve();
    setState({ load, view, pending: true, error: null, attempt: { index, cursors } });
    return request(index, cursors);
  }
  return {
    view,
    pending,
    error,
    reload: () => start(0, [undefined]),
    retry: () => start(attempt.index, attempt.cursors),
    previous: () => {
      if (view && view.index > 0)
        void start(view.index - 1, view.cursors.slice(0, view.index)).catch(() => {});
    },
    next: () => {
      if (view?.page.next)
        void start(view.index + 1, [...view.cursors, view.page.next]).catch(() => {});
    },
  };
}
