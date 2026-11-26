// React for the type check (F16), loosely: React itself is barely typed here, and a component's
// props are what its function reads, each one optional and of any type, so the check finds
// missing names and wrong calls without a type for every prop. jsconfig.json points 'react' and
// 'react-dom/client' here. Swap for @types/react when files move to TypeScript.
declare class Component { constructor(props?: any); props: any; state: any; setState(s: any): void }
declare const React: { Component: typeof Component; [name: string]: any };
export default React;
export declare const createRoot: (el: Element) => { render(node: any): void; unmount(): void };
declare global {
  namespace JSX {
    type Element = any;
    interface IntrinsicElements { [name: string]: any }
    type LibraryManagedAttributes<C, P> = { [K in keyof P]?: any } & { [prop: string]: any };
    interface ElementChildrenAttribute { children: {} }
  }
}
