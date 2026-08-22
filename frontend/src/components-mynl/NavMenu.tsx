import {
  Menubar,
  MenubarContent,
  MenubarItem,
  MenubarMenu,
  MenubarTrigger,
} from "@/components/ui/menubar";
import { Menu } from "lucide-react";

interface NavMenuProps {
  onBackToHome: () => void;
  onToAbout: () => void;
}

export function NavMenu({ onBackToHome, onToAbout }: NavMenuProps) {
  return (
    <div className="relative z-1 flex flex-row items-center justify-between bg-black/30 px-5 backdrop-blur-md">
      <span className="text-white font-bold">MYNL</span>
      <Menubar className="border-0">
        <MenubarMenu>
          <MenubarTrigger>
            <Menu color="white" />
          </MenubarTrigger>
          <MenubarContent>
            <MenubarItem onClick={onBackToHome}>Home</MenubarItem>
            <MenubarItem onClick={onToAbout}>About</MenubarItem>
          </MenubarContent>
        </MenubarMenu>
      </Menubar>
    </div>
  );
}
