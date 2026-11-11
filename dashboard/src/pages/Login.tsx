import { Button } from "@/components/ui/button";
import { redirectToLogin } from "@/lib/auth";

function Login() {
  return (
    <div className="flex min-h-dvh items-center justify-center p-5">
      <div className="flex w-full max-w-sm flex-col items-center gap-6 rounded-2xl border bg-card p-8 text-center text-card-foreground shadow-lg">
        <h1 className="text-xl font-semibold">
          Maybe You're Not Lost — Dashboard
        </h1>
        <Button className="w-full" size="lg" onClick={redirectToLogin}>
          Sign in with Microsoft
        </Button>
      </div>
    </div>
  );
}

export default Login;
