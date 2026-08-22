import { Button } from "../components/ui/button";

interface HomeProps {
  onEncourageSomeone: () => void;
  onBeEncouraged: () => void;
}

function Home({ onEncourageSomeone, onBeEncouraged }: HomeProps) {
  return (
    <div className="flex flex-col gap-3 pt-30 px-2">
      <Button className="text-xl" onClick={onEncourageSomeone}>
        Encourage Someone
      </Button>
      <Button className="text-xl" onClick={onBeEncouraged}>
        Be Encouraged
      </Button>
    </div>
  );
}

export default Home;
