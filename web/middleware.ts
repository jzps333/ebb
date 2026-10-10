// Refreshes the login session and redirects logged-out users to /login.
// TODO: Teammate 2 builds this.

import { NextResponse } from "next/server";

export function middleware() {
  return NextResponse.next();
}
