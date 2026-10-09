export let handler: (req: Request) => Response | Promise<Response>;
export function serve(h: (req: Request) => Response | Promise<Response>): void { handler = h; }
