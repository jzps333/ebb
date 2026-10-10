// Finishes sign-in for email links (or Google, if added later).
// TODO: Teammate 2 builds this.

import { NextResponse } from "next/server";

export async function GET(request: Request) {
  return NextResponse.redirect(new URL("/", request.url));
}
