import {
  Menubar,
  MenubarContent,
  MenubarItem,
  MenubarMenu,
  MenubarTrigger,
} from "@/components/ui/menubar";
import { Menu } from "lucide-react";

export function NavMenu() {
  return (
    <div className="relative z-10 flex flex-row items-center justify-between bg-black/30 px-5 backdrop-blur-md">
      <span className="text-white font-bold">MYNL</span>
      <Menubar className="border-0">
        <MenubarMenu>
          <MenubarTrigger>
            <Menu color="white" />
          </MenubarTrigger>
          <MenubarContent>
            <MenubarItem onClick={() => {}}>Home</MenubarItem>
            <MenubarItem onClick={() => {}}>Encourage Someone</MenubarItem>
            <MenubarItem onClick={() => {}}>Be Encouraged</MenubarItem>
          </MenubarContent>
        </MenubarMenu>
      </Menubar>
    </div>
  );
}
