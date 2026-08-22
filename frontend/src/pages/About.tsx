import { Button } from "../components/ui/button";

interface AboutProps {
  onBackToHome: () => void;
}

export function About({ onBackToHome }: AboutProps) {
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto px-2 pt-6 pb-10">
      <div className="flex flex-col gap-4 text-base leading-relaxed">
        <p>
          In the last month of Luc Stout's life, he started to dream of a
          project that would help others who felt like he did. He was inspired
          by the story of the disciples on the road to Emmaus.
        </p>
        <p>
          If you don't know this story, here's a quick refresher &mdash; Jesus
          has been crucified, but three days have passed and the tomb is empty.
          The disciples are overcome with grief and confusion.
        </p>
        <div className="flex flex-col gap-2 border-l-2 border-white/30 pl-4 italic text-muted-foreground">
          <p>Where has their savior gone?</p>
          <p>Was it all for nothing?</p>
          <p>
            What if everything they had invested their lives in wasn't true?
          </p>
        </div>
        <p>
          And as two disciples walk and grieve, they are joined by a stranger.
          The stranger listens to them in their confusion and questioning, but
          they don't recognize that the stranger walking with them is Jesus
          himself.
        </p>
        <p>
          Luc was moved by this story and moved to consider its deeper
          implications: what if we, like the disciples, are missing that even in
          our moments of deepest grief, anguish, and confusion, we're not lost
          and alone after all.
        </p>
        <p>
          What if the stranger walking with us is our savior himself? Patient
          and kind, compassionate and merciful, more alive and present than we
          could even imagine.
        </p>
        <p>
          From this story was born an idea for a project called{" "}
          <span className="font-semibold">"Maybe You're Not Lost."</span>
        </p>
        <p>
          This project would be centered around offering tangible encouragement
          to individuals in crisis, specifically believers struggling with ideas
          of taking their own lives.
        </p>
        <p>This encouragement would initially be available in two ways:</p>
        <ol className="flex list-decimal flex-col gap-3 pl-6 marker:font-semibold">
          <li>
            Through short form and long form content on social media and longer
            form written articles by Christians who had struggled and found
            hope, pastors, mental health professionals etc.
          </li>
          <li>
            Through an opportunity for individuals who are struggling to hit a
            button somewhere asking for encouragement and help and then
            immediately receive a message from another Christian, encouraging
            them to stay alive, to fight to see tomorrow, to recognize the
            stranger on the road with them as Jesus Christ &mdash; to remind
            them that maybe they're not actually lost, maybe they're right where
            they're supposed to be.
          </li>
        </ol>
        <p>
          Luc didn't get to see this project become a reality but we have all of
          his plans for it. He had trusted his family with this idea, had asked
          them what they thought &mdash; they were all for it.
        </p>
        <p>So now, his family wants to make his ideas a reality.</p>
        <p className="font-semibold">
          The mission of MYNL is simple &mdash; remind people, like Luc, that
          even if they feel lost, they're not.
        </p>
        <p>
          Join us today by encouraging others to keep fighting, by asking for
          encouragement if you need it, or by giving to a camp fund in Luc's
          honor.
        </p>
      </div>
      <Button onClick={onBackToHome}>Back To Home</Button>
    </div>
  );
}

export default About;
