import { createRouter, useMatch, useRouteMatches, type RouteSectionProps } from "@solidjs/router";
import { render } from "@solidjs/web";
import { createEffect } from "solid-js";
import App, { SiteFooter, SiteHeader } from "./App";
import { Privacy, Terms } from "./Policies";
import "./styles.css";

const Router = createRouter({
  base: import.meta.env.BASE_URL,
  routes: [
    { path: "/", component: App },
    { path: "/privacy", component: Privacy, info: { title: "Privacy policy · LeNotch", description: "What stays on your Mac and what LeNotch sends when you use a connected feature." } },
    { path: "/terms", component: Terms, info: { title: "Terms of use · LeNotch", description: "The terms for using the LeNotch app and website." } },
  ],
});

function Layout(props: RouteSectionProps) {
  const home = useMatch(() => import.meta.env.BASE_URL);
  const matches = useRouteMatches();
  const description = document.querySelector<HTMLMetaElement>('meta[name="description"]')!;
  const defaultTitle = document.title;
  const defaultDescription = description.content;
  createEffect(() => matches().at(-1)?.route.info, (info) => {
    document.title = info?.title ?? defaultTitle;
    description.content = info?.description ?? defaultDescription;
  });
  return (
    <>
      <SiteHeader home={!!home()} />
      {props.children}
      <SiteFooter home={!!home()} />
    </>
  );
}

render(() => <Router>{Layout}</Router>, document.getElementById("root")!);
