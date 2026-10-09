// deno-lint-ignore-file no-explicit-any
type Row = Record<string, any>;
type Err = { message: string } | null;
interface Q extends PromiseLike<{ data: Row[] | null; error: Err; count: number | null }> {
  select(...a: any[]): Q; insert(...a: any[]): Q; update(...a: any[]): Q; upsert(...a: any[]): Q;
  eq(...a: any[]): Q; neq(...a: any[]): Q; ilike(...a: any[]): Q; in(...a: any[]): Q; order(...a: any[]): Q; limit(...a: any[]): Q;
  maybeSingle(): Promise<{ data: Row | null; error: Err }>;
  single(): Promise<{ data: Row; error: Err }>;
}
interface Client {
  from(t: string): Q;
  auth: { admin: {
    createUser(a: any): Promise<{ data: { user: Row | null }; error: Err }>;
    updateUserById(id: string, a: any): Promise<{ data: any; error: Err }>;
    getUserById(id: string): Promise<{ data: { user: Row | null }; error: Err }>;
    deleteUser(id: string): Promise<{ data: any; error: Err }>;
  } };
}
export function createClient(..._a: any[]): Client { return {} as Client; }
