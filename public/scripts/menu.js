if (typeof cssmenu_no_js === 'undefined') {
    var open_main_item = null;

    function handleMenuClick(container, e, isHamburger){
        container.classList.toggle('open');

        // Only one dropdown can be open at a time
        if (open_main_item !== container && open_main_item !== null) {
            open_main_item.classList.remove("open");
        }

        // On mobiles devices the hamburger toggles the menu
        if (!isHamburger) {
            open_main_item = container.classList.contains('open') ? container: null;
        }
        e.stopPropagation();
        return false;
    }

    // menu button for mobile devices
    var dom_hamburger = document.body.querySelector(".hamburger.expand-toggle");
    dom_hamburger.addEventListener('click', function(evt){
        return handleMenuClick(dom_hamburger.parentNode, evt, true);
    });

    var expandToggles = document.body.querySelectorAll("#cssmenu .expand-toggle");
    // HTMLCollections don't expose a forEach
    [].forEach.call(expandToggles, function(expandToggle){
        expandToggle.addEventListener("click", function(e) {
            return handleMenuClick(expandToggle.parentNode, e, false);
        });
    });

    // close window on clicks to other regions
    window.addEventListener("click", function(e) {
        if (open_main_item !== null) {
            open_main_item.classList.remove("open");
        }
        open_main_item = null;
    });
}
