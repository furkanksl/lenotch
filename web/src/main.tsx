import { render } from "@solidjs/web";
import App from "./App";
import "./styles.css";

const root = document.getElementById("root");

if (!root) throw new Error("Missing #root mount element");

render(() => <App />, root);
