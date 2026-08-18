import { Button } from "./components/ui/button";

const ENCOURAGEMENTS = [
  "You are doing better than you think.",
  "One step at a time is still progress.",
  "You've gotten through hard days before. You can get through this one too.",
  "It's okay to not have it all figured out yet.",
  "You matter, even on the days it doesn't feel like it.",
];

function App() {
  const encourageSomeone = async () => {
    const text =
      ENCOURAGEMENTS[Math.floor(Math.random() * ENCOURAGEMENTS.length)];

    await fetch("/encouragements", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
  };

  return (
    <>
      <div>MaybeYoureNotLost</div>
      <Button onClick={encourageSomeone}>Encourage Someone</Button>
    </>
  );
}

export default App;
